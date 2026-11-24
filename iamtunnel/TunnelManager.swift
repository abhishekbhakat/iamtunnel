import Darwin
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    private struct ProcessIdentity: Codable, Equatable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        static func read(_ pid: Int32) -> Self? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pgid == UInt32(pid) else { return nil }
            return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        }

        var isCurrent: Bool { Self.read(pid) == self }
    }

    private final class Session {
        let tunnel: Tunnel
        let onStatusChange: (TunnelStatus) -> Void
        var keepAlive: Bool
        var process: Process?
        var restored: ProcessIdentity?
        var exitSource: DispatchSourceProcess?
        var work: Task<Void, Never>?
        var retryPending = false

        init(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
            self.tunnel = tunnel
            self.keepAlive = tunnel.keepAlive
            self.onStatusChange = onStatusChange
        }

        var id: UUID { tunnel.id }
        var pid: Int32? { process?.processIdentifier ?? restored?.pid }
    }

    private let retainedKey = "retainedTunnelProcesses"
    private lazy var retained: [String: ProcessIdentity] = {
        guard let data = UserDefaults.appDefaults.data(forKey: retainedKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProcessIdentity].self, from: data)) ?? [:]
    }()
    private var sessions: [UUID: Session] = [:]
    private var isShuttingDown = false

    func connect(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard !isShuttingDown, sessions[tunnel.id] == nil else { return }
        let session = Session(tunnel: tunnel, onStatusChange: onStatusChange)
        sessions[tunnel.id] = session
        session.onStatusChange(.starting)
        start(session, retrying: false)
    }

    func updateKeepAlive(for tunnel: Tunnel) {
        guard let session = sessions[tunnel.id] else { return }
        let endpointChanged = (session.keepAlive || tunnel.keepAlive) && !session.tunnel.usesSameEndpoint(as: tunnel)
        session.keepAlive = tunnel.keepAlive
        if endpointChanged || (!session.keepAlive && session.retryPending) {
            disconnect(tunnel: tunnel, onStatusChange: session.onStatusChange)
        }
    }

    private func start(_ session: Session, retrying: Bool) {
        session.work = Task { [weak self, weak session] in
            guard let self, let session, isActive(session) else { return }
            let tunnel = session.tunnel
            if let existingPid = listeningPIDs(tunnel.localPort).first {
                // Reconnects must wait for the port rather than evict another process.
                if retrying {
                    attemptEnded(session)
                    return
                }
                kill(existingPid, SIGKILL)
                try? await Task.sleep(for: .milliseconds(500))
                guard isActive(session) else { return }
            }

            let target = if tunnel.ssmTarget.hasPrefix("i-") {
                tunnel.ssmTarget
            } else {
                await resolveNameTag(tunnel: tunnel)
            }
            guard isActive(session) else { return }
            guard let target else {
                attemptEnded(session)
                return
            }

            let params = """
            {"host":["\(tunnel.remoteHost)"],"portNumber":["\(tunnel.remotePort)"],"localPortNumber":["\(tunnel.localPort)"]}
            """
            var args = ["ssm", "start-session", "--target", target,
                        "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
                        "--parameters", params, "--region", tunnel.region]
            if !tunnel.profile.isEmpty { args += ["--profile", tunnel.profile] }
            let process = Self.awsProcess(args: args)
            // A retained session must not rely on pipes whose reader exits with the app.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self, weak session] exited in
                Task { @MainActor in
                    guard let self, let session, self.isActive(session), session.process === exited else { return }
                    self.processEnded(session, pid: exited.processIdentifier)
                }
            }

            do {
                try process.run()
                session.process = process
                await watchForListener(session)
            } catch {
                debugLog("Failed to start SSM session: \(error)")
                attemptEnded(session)
            }
        }
    }

    private func watchForListener(_ session: Session) async {
        let fallback = ContinuousClock.now.advanced(by: .seconds(3))
        guard let pid = session.pid else { return }
        while isActive(session), session.pid == pid {
            guard session.process?.isRunning ?? (session.restored?.isCurrent == true) else { return }
            if listeningPIDs(session.tunnel.localPort).contains(where: { getpgid($0) == pid })
                || (!session.keepAlive && ContinuousClock.now >= fallback) {
                session.onStatusChange(.connected)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func processEnded(_ session: Session, pid: Int32) {
        stopOrphanedPlugin(for: session, group: pid)
        session.process = nil
        session.restored = nil
        session.exitSource?.cancel()
        session.exitSource = nil
        attemptEnded(session)
    }

    private func attemptEnded(_ session: Session) {
        session.work?.cancel()
        guard session.keepAlive else {
            remove(session)
            session.onStatusChange(.stopped)
            return
        }
        session.retryPending = true
        session.onStatusChange(.starting)
        session.work = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let session, !Task.isCancelled, isActive(session) else { return }
            session.retryPending = false
            start(session, retrying: true)
        }
    }

    func restore(tunnel: Tunnel, onStatusChange: @escaping (TunnelStatus) -> Void) {
        guard !isShuttingDown, sessions[tunnel.id] == nil,
              let identity = retained.removeValue(forKey: tunnel.id.uuidString) else { return }
        saveRetained()
        guard identity.isCurrent else { return }

        let session = Session(tunnel: tunnel, onStatusChange: onStatusChange)
        session.restored = identity
        sessions[tunnel.id] = session
        session.onStatusChange(.starting)
        let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
        let handleExit = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.isActive(session), session.restored == identity else { return }
                self.processEnded(session, pid: identity.pid)
            }
        }
        source.setEventHandler { _ = handleExit() }
        source.setRegistrationHandler {
            if !identity.isCurrent { _ = handleExit() }
        }
        session.exitSource = source
        source.resume()
        session.work = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await watchForListener(session)
        }
    }

    func disconnect(tunnel: Tunnel, onStatusChange: (TunnelStatus) -> Void) {
        if let session = sessions[tunnel.id] {
            remove(session)
            stopProcess(session)
        }
        onStatusChange(.stopped)
    }

    func disconnectAll() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let active = Array(sessions.values)
        for session in active {
            remove(session)
            if session.keepAlive {
                let identity = session.restored ?? session.pid.flatMap(ProcessIdentity.read)
                if let identity, identity.isCurrent {
                    retained[session.id.uuidString] = identity
                }
            } else {
                stopProcess(session)
            }
        }
        retained = retained.filter { $0.value.isCurrent }
        saveRetained()

        // The legacy fallback would also kill sessions marked to survive either quit.
        if retained.isEmpty && !active.contains(where: \.keepAlive) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-9", "-f", "ssm start-session"]
            if (try? task.run()) != nil { task.waitUntilExit() }
        }
    }

    private func saveRetained() {
        if retained.isEmpty {
            UserDefaults.appDefaults.removeObject(forKey: retainedKey)
        } else if let data = try? JSONEncoder().encode(retained) {
            UserDefaults.appDefaults.set(data, forKey: retainedKey)
        }
    }

    private func isActive(_ session: Session) -> Bool {
        !isShuttingDown && !Task.isCancelled && sessions[session.id] === session
    }

    private func remove(_ session: Session) {
        sessions.removeValue(forKey: session.id)
        session.work?.cancel()
        session.exitSource?.cancel()
    }

    private func stopProcess(_ session: Session) {
        guard let pid = session.pid else { return }
        if session.process?.isRunning ?? (session.restored?.isCurrent == true) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        } else {
            stopOrphanedPlugin(for: session, group: pid)
        }
    }

    private func stopOrphanedPlugin(for session: Session, group: Int32) {
        // Match the listener to the original group and rule out a reused leader PID.
        guard getpgid(group) == -1 || session.restored?.isCurrent == true,
              listeningPIDs(session.tunnel.localPort).contains(where: { getpgid($0) == group }) else { return }
        kill(-group, SIGKILL)
    }

    private func listeningPIDs(_ port: Int) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "tcp:\(port)", "-s", "TCP:LISTEN", "-t"]
        return Self.output(of: process).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private func resolveNameTag(tunnel: Tunnel) async -> String? {
        var args = ["ec2", "describe-instances", "--filters", "Name=tag:Name,Values=\(tunnel.ssmTarget)",
                    "--query", "Reservations[0].Instances[0].InstanceId", "--output", "text", "--region", tunnel.region]
        if !tunnel.profile.isEmpty { args += ["--profile", tunnel.profile] }
        let result = await Task.detached(priority: .utility) { [args] in
            Self.output(of: Self.awsProcess(args: args))
        }.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "None" ? nil : result
    }

    private nonisolated static func awsProcess(args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["aws"] + args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        return process
    }

    private nonisolated static func output(of process: Process) -> String {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
