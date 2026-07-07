import SwiftUI

/// Root screen: the list of saved VPN profiles (WireGuard-app style). Tap a row
/// to see its detail; toggle a row to connect/disconnect; `+` adds a profile.
struct TunnelListView: View {
    @EnvironmentObject private var manager: TunnelsManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if manager.tunnels.isEmpty {
                    ContentUnavailableView {
                        Label("No profiles", systemImage: "network")
                    } description: {
                        Text("Tap + to add a VPN profile.")
                    }
                } else {
                    List {
                        ForEach(manager.tunnels) { tunnel in
                            TunnelRowView(tunnel: tunnel)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("ezvpn")
            .navigationDestination(for: TunnelContainer.ID.self) { id in
                if let tunnel = manager.tunnels.first(where: { $0.id == id }) {
                    TunnelDetailView(tunnel: tunnel)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add profile", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                NavigationStack { TunnelEditView(mode: .add) }
            }
            .refreshable { await manager.reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await manager.reload() } }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        let targets = offsets.map { manager.tunnels[$0] }
        Task {
            for tunnel in targets {
                try? await manager.remove(tunnel)
            }
        }
    }
}
