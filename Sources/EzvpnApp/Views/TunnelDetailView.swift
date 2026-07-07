import SwiftUI
import NetworkExtension

/// Detail for one profile: connection status, live applied-routing state (from
/// the tunnel process), connect/disconnect, and edit/delete.
struct TunnelDetailView: View {
    @ObservedObject var tunnel: TunnelContainer
    @EnvironmentObject private var manager: TunnelsManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    private var isConnecting: Bool {
        tunnel.status == .connecting || tunnel.status == .reasserting
            || tunnel.isWaiting || tunnel.isRestarting
    }

    /// The session is doing anything at all — connect is locked until it stops.
    private var isActive: Bool {
        tunnel.status.isInOperation || tunnel.isWaiting || tunnel.isRestarting
    }

    var body: some View {
        Form {
            Section("Status") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(tunnel.status.indicatorColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                    Spacer()
                    if tunnel.status == .connected, let since = tunnel.connectedDate {
                        Text(since, style: .relative)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let err = tunnel.lastError {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }
            }

            // Live routing state reported by the tunnel process itself, so
            // what's on screen is what the interface actually got.
            if tunnel.status == .connected, let info = tunnel.runtimeInfo {
                Section {
                    if let ip = info.assignedIP {
                        RouteRow(title: "Assigned IPv4", values: [ip])
                    }
                    if let ip6 = info.assignedIP6 {
                        RouteRow(title: "Assigned IPv6", values: [ip6])
                    }
                    RouteRow(title: "Tunnel routes (IPv4)", values: info.includedRoutes)
                    RouteRow(title: "Tunnel routes (IPv6)", values: info.includedRoutes6)
                    RouteRow(title: "Bypass routes (IPv4)", values: info.bypassRoutes)
                    RouteRow(title: "Bypass routes (IPv6)", values: info.bypassRoutes6)
                } header: {
                    Text("Active routes")
                } footer: {
                    Text("Bypass routes are server underlay/relay addresses excluded from the tunnel so its own transport is never captured. Pull to refresh.")
                }
            }

            Section { connectButton }

            Section {
                Button("Edit") { showingEdit = true }
                    .disabled(isActive)
                Button("Delete Profile", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(tunnel.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await tunnel.refreshRuntimeInfo() }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { TunnelEditView(mode: .edit(tunnel)) }
        }
        .confirmationDialog(
            "Delete \(tunnel.name)?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await manager.remove(tunnel)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the VPN configuration from this device.")
        }
    }

    private var statusText: String {
        if tunnel.isWaiting { return "Waiting…" }
        if tunnel.isRestarting { return "Reconnecting…" }
        return tunnel.status.displayText
    }

    @ViewBuilder
    private var connectButton: some View {
        if isConnecting {
            HStack(spacing: 12) {
                ProgressView()
                Text(tunnel.isWaiting || tunnel.isRestarting || tunnel.status == .reasserting
                    ? "Reconnecting…" : "Connecting…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { manager.startDeactivation(of: tunnel) }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } else if isActive {
            Button("Disconnect", role: .destructive) {
                manager.startDeactivation(of: tunnel)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(tunnel.status == .disconnecting)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } else {
            Button("Connect") {
                Task { await manager.startActivation(of: tunnel) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}
