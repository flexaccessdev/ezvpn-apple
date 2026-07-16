#if os(macOS)
import AppKit
import NetworkExtension
import SwiftUI

/// Native macOS menu-bar controls for opening the app and toggling profiles
/// without keeping the main window visible.
struct MenuBarView: View {
    @EnvironmentObject private var manager: TunnelsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            NSApplication.shared.setActivationPolicy(.regular)
            openWindow(id: EzvpnScene.mainWindowID)
            NSApplication.shared.activate()
        } label: {
            Label("Open ezvpn", systemImage: "macwindow")
        }

        Divider()

        if manager.tunnels.isEmpty {
            Text("No profiles")
        } else {
            Section("Profiles") {
                ForEach(manager.tunnels) { tunnel in
                    MenuBarTunnelButton(tunnel: tunnel)
                }
            }
        }

        Divider()

        Button("Quit ezvpn") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct MenuBarTunnelButton: View {
    @ObservedObject var tunnel: TunnelContainer
    @EnvironmentObject private var manager: TunnelsManager

    var body: some View {
        Button {
            Task {
                if isOn {
                    manager.startDeactivation(of: tunnel)
                } else {
                    await manager.startActivation(of: tunnel)
                }
            }
        } label: {
            Label(actionTitle, systemImage: statusSymbol)
        }
        .disabled(tunnel.status == .disconnecting)
    }

    private var isOn: Bool {
        tunnel.status.isInOperation || tunnel.isWaiting
    }

    private var actionTitle: String {
        if tunnel.status == .disconnecting {
            return "\(tunnel.name) — Disconnecting…"
        }
        return "\(isOn ? "Disconnect" : "Connect") \(tunnel.name)"
    }

    private var statusSymbol: String {
        if tunnel.isWaiting { return "clock" }
        if tunnel.isRestarting { return "arrow.triangle.2.circlepath" }
        switch tunnel.status {
        case .invalid: return "exclamationmark.triangle"
        case .disconnected: return "lock.shield"
        case .connecting, .reasserting: return "arrow.triangle.2.circlepath"
        case .connected: return "lock.shield.fill"
        case .disconnecting: return "stop.circle"
        @unknown default: return "network"
        }
    }
}
#endif
