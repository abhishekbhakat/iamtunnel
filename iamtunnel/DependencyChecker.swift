import Foundation

struct DependencyStatus: Sendable {
    var awsCLI: Bool = false
    var awsCLIVersion: String = ""
    var awsCredentials: Bool = false
    var awsCredentialsDetail: String = ""
    var sessionManagerPlugin: Bool = false

    var allGood: Bool {
        awsCLI && awsCredentials && sessionManagerPlugin
    }
}

final class DependencyChecker: @unchecked Sendable {
    static let shared = DependencyChecker()

    private let queue = DispatchQueue(label: "iamtunnel.dependencies", qos: .utility)
    // The serial queue owns all reads and writes to the cache.
    private var awsVersionCache: (path: String, checkedAt: ContinuousClock.Instant, version: String)?

    private init() {}

    func check() async -> DependencyStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.probeDependencies())
            }
        }
    }

    private func probeDependencies() -> DependencyStatus {
        print("🔍 DependencyChecker.check() called")
        var status = DependencyStatus()

        // ── 1. AWS CLI ───────────────────────────────────────
        // Check common install paths directly instead of relying on PATH
        let awsPaths = [
            "/usr/local/bin/aws",
            "/opt/homebrew/bin/aws",
            "/usr/bin/aws",
            "/opt/local/bin/aws"
        ]
        if let awsPath = awsPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let awsResult = awsVersion(at: awsPath)
            print("🔍 AWS CLI check: \(awsResult)")
            if awsResult.contains("aws-cli") {
                status.awsCLI = true
                status.awsCLIVersion = awsResult.components(separatedBy: " ").first ?? ""
            }
        } else {
            awsVersionCache = nil
            print("🔍 AWS CLI not found in any known path")
        }

        // ── 2. AWS credentials — check file/env/config ──────
        let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials")
        let credentialsExist = FileManager.default.fileExists(atPath: credentialsFile.path)

        let envCredentials = ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != nil &&
                             ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] != nil

        let configFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        let configContent = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let hasSSOorProcess = configContent.contains("sso_start_url") ||
                              configContent.contains("credential_process") ||
                              configContent.contains("role_arn")

        status.awsCredentials = credentialsExist || envCredentials || hasSSOorProcess
        status.awsCredentialsDetail = status.awsCredentials ? "Configured" : "Run `aws configure`"

        // ── 3. Session Manager Plugin ────────────────────────
        let pluginPaths = [
            "/usr/local/sessionmanagerplugin/bin/session-manager-plugin",
            "/usr/local/bin/session-manager-plugin",
            "/opt/homebrew/bin/session-manager-plugin"
        ]
        status.sessionManagerPlugin = pluginPaths.contains {
            FileManager.default.fileExists(atPath: $0)
        }
        print("🔍 Session Manager Plugin: \(status.sessionManagerPlugin)")

        return status
    }

    private func awsVersion(at path: String) -> String {
        if let cache = awsVersionCache, cache.path == path,
           cache.checkedAt.duration(to: .now) < .seconds(60) {
            return cache.version
        }

        let version = run(path, args: ["--version"])
        awsVersionCache = (path, .now, version)
        return version
    }

    private func run(_ command: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
