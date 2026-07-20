import SwiftUI

/// On-demand "connection path" readout: a point-in-time snapshot of how the
/// running tunnel reaches the server (the live iroh relay/direct paths),
/// mirroring `ezvpn client status` and flextunnel-ios's sheet of the same name.
///
/// Presented from the tunnel detail screen, which only offers it while the
/// tunnel is connected — the core routes over no path while disconnected, so
/// the snapshot would be empty. The snapshot is captured on appear and
/// re-captured by Refresh; unlike flextunnel's in-process query this one is a
/// round trip to the tunnel extension, hence async.
struct ConnPathSheet: View {
    /// Snapshots the live paths right now (`TunnelContainer.queryConnPaths()`).
    let query: () async -> TunnelConnectionSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var paths: [TunnelConnectionPath] = []
    @State private var customRelays: [TunnelCustomRelay] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if paths.isEmpty {
                        Text("No path yet — still establishing. Close this and try again in a moment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(paths) { path in
                            ConnPathRow(path: path)
                        }
                    }
                } footer: {
                    Text("Snapshot taken just now — how this session reaches the server. Direct paths are peer-to-peer; relay paths hop through an iroh relay.")
                }
                if !customRelays.isEmpty {
                    Section {
                        ForEach(customRelays) { relay in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(relay.url)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(relayStatus(relay))
                                    .font(.caption)
                                    .foregroundStyle(relay.working == true ? .green : .secondary)
                            }
                        }
                    } header: {
                        Text("Custom relays")
                    } footer: {
                        Text("Health is reported by the running iroh endpoint; unavailable means it has not observed this relay yet.")
                    }
                }
            }
            .navigationTitle("Connection path")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task { await refresh() }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #elseif os(macOS)
        .presentationSizing(.fitted)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }

    private func refresh() async {
        let snapshot = await query()
        paths = snapshot.paths
        customRelays = snapshot.customRelays
    }

    private func relayStatus(_ relay: TunnelCustomRelay) -> String {
        switch relay.working {
        case true: return "Working"
        case false: return relay.error.map { "Not working — \($0)" } ?? "Not working"
        case nil: return "Status unavailable"
        }
    }
}

/// One path row: a transport-colored dot, the human-readable path line, and an
/// "active" pill on the path iroh currently routes over.
private struct ConnPathRow: View {
    let path: TunnelConnectionPath

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(path.display)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if path.selected {
                Text("active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch path.kind {
        case .direct: return .green
        case .relay: return .orange
        case .other: return .gray
        }
    }
}
