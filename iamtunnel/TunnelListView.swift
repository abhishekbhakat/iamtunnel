import SwiftUI

struct TunnelListView: View {
    @State private var tunnels: [Tunnel] = ConnectionStore.shared.load()
    @State private var connectionWindow: NSWindow?
    @State private var editWindow: NSWindow?
    @State private var depStatus: DependencyStatus?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                tunnelContent
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            debugLog("👀 TunnelListView appeared")
            restoreExistingTunnels()
            postActiveCount()
        }
        .task {
            let status = await DependencyChecker.shared.check()
            guard !Task.isCancelled else { return }
            depStatus = status
        }
    }

    private var tunnelContent: some View {
        VStack(spacing: 0) {
            if let depStatus, !depStatus.allGood {
                DependencyWarningView(status: depStatus)
                Divider()
            }

            NewConnectionRow { openNewConnectionWindow() }
            Divider()

            Text("Tunnels")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if tunnels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No connections yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Click + to add one")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            } else {
                ForEach(tunnels) { tunnel in
                    TunnelRowView(tunnel: tunnel) {
                        toggleTunnel(tunnel)
                    } onEdit: {
                        openEditWindow(for: tunnel)
                    } onDelete: {
                        TunnelManager.shared.disconnect(tunnel: tunnel) { _ in }
                        tunnels.removeAll { $0.id == tunnel.id }
                        ConnectionStore.shared.save(tunnels)
                        postActiveCount()
                    } onKeepAliveToggle: {
                        toggleKeepAlive(for: tunnel.id)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings...") {
                (NSApp.delegate as? AppDelegate)?.openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(.primary)
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(.primary)
            Text("⌘Q")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func restoreExistingTunnels() {
        for tunnel in tunnels where tunnel.status == .stopped {
            TunnelManager.shared.restore(tunnel: tunnel) { newStatus in
                updateStatus(of: tunnel, to: newStatus)
            }
        }
    }

    private func toggleKeepAlive(for id: UUID) {
        guard let index = tunnels.firstIndex(where: { $0.id == id }) else { return }
        tunnels[index].keepAlive.toggle()
        ConnectionStore.shared.save(tunnels)
        TunnelManager.shared.updateKeepAlive(for: tunnels[index])
    }

    // ── Open new connection window ───────────────────────────
    private func openNewConnectionWindow() {
        if connectionWindow == nil {
            let view = NewConnectionView { newTunnel in
                tunnels.append(newTunnel)
                ConnectionStore.shared.save(tunnels)
                connectionWindow?.close()
                connectionWindow = nil
            } onCancel: {
                connectionWindow?.close()
                connectionWindow = nil
            }
            connectionWindow = makeConnectionWindow(for: view, title: "New Connection")
        }
        connectionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Open edit connection window ──────────────────────────
    private func openEditWindow(for tunnel: Tunnel) {
        editWindow?.close()
        editWindow = nil

        let view = NewConnectionView(editing: tunnel) { updated in
            if let i = tunnels.firstIndex(where: { $0.id == updated.id }) {
                var updated = updated
                updated.status = tunnels[i].status
                tunnels[i] = updated
                ConnectionStore.shared.save(tunnels)
                TunnelManager.shared.updateKeepAlive(for: updated)
            }
            editWindow?.close()
            editWindow = nil
        } onCancel: {
            editWindow?.close()
            editWindow = nil
        }
        editWindow = makeConnectionWindow(for: view, title: "Edit Connection")
        editWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeConnectionWindow(for view: NewConnectionView, title: String) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(NewConnectionView.windowContentSize)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // ── Toggle tunnel connect/disconnect ─────────────────────
    private func toggleTunnel(_ tunnel: Tunnel) {
        if tunnel.status == .stopped {
            TunnelManager.shared.connect(tunnel: tunnel) { newStatus in
                updateStatus(of: tunnel, to: newStatus)
            }
        } else {
            TunnelManager.shared.disconnect(tunnel: tunnel) { newStatus in
                updateStatus(of: tunnel, to: newStatus)
                NotificationManager.shared.notifyDisconnected(tunnel: tunnel)
            }
        }
    }

    private func updateStatus(of tunnel: Tunnel, to status: TunnelStatus) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }),
              tunnels[index].status != status else { return }
        tunnels[index].status = status
        if status == .connected {
            NotificationManager.shared.notifyConnected(tunnel: tunnel)
        }
        postActiveCount()
    }

    // ── Post active tunnel count to menu bar icon ────────────
    private func postActiveCount() {
        let count = tunnels.filter { $0.status == .connected }.count
        NotificationCenter.default.post(
            name: .tunnelStatusChanged,
            object: nil,
            userInfo: ["activeCount": count]
        )
    }
}

// ── New connection row ───────────────────────────────────────
struct NewConnectionRow: View {
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07))
                .clipShape(Circle())
            Text("New connection")
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onTapGesture { action() }
    }
}

#Preview {
    TunnelListView()
}
