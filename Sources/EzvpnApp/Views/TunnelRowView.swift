import SwiftUI

/// One profile row: a status dot + name + status text (the navigable area), and
/// a trailing connect toggle. The `NavigationLink` and `Toggle` are siblings so
/// each handles its own taps (tapping the toggle connects; tapping the rest
/// navigates to the detail screen).
struct TunnelRowView: View {
    @ObservedObject var tunnel: TunnelContainer
    @EnvironmentObject private var manager: TunnelsManager

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: tunnel.id) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(tunnel.status.indicatorColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tunnel.name)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("", isOn: connectBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(tunnel.status == .disconnecting)
        }
    }

    private var isOn: Bool {
        tunnel.status.isInOperation || tunnel.isWaiting
    }

    private var connectBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                Task {
                    if on {
                        await manager.startActivation(of: tunnel)
                    } else {
                        manager.startDeactivation(of: tunnel)
                    }
                }
            }
        )
    }

    private var statusText: String {
        if tunnel.isWaiting { return "Waiting…" }
        if tunnel.isRestarting { return "Reconnecting…" }
        return tunnel.status.displayText
    }
}
