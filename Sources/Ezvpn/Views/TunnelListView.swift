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
            #if os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                SystemExtensionBanner(state: manager.systemExtensionState)
            }
            #endif
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

#if os(macOS)
import AppKit

/// macOS-only banner that reports packet-tunnel system-extension state. The
/// tunnel can't run until the extension is `.active`, so `.needsApproval` and
/// `.failed` are surfaced prominently; `.idle`/`.activating`/`.active` render
/// nothing (activation is quick and the happy path needs no chrome).
private struct SystemExtensionBanner: View {
    let state: SystemExtensionState

    var body: some View {
        switch state {
        case .needsApproval:
            banner(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                message: "Allow the ezvpn network extension in System Settings "
                    + "to enable the VPN.",
                actionTitle: "Open System Settings",
                action: openSystemSettings)
        case .failed(let detail):
            banner(
                icon: "xmark.octagon.fill",
                tint: .red,
                message: "Couldn't install the network extension: \(detail)",
                actionTitle: nil,
                action: nil)
        case .idle, .activating, .active:
            EmptyView()
        }
    }

    @ViewBuilder
    private func banner(
        icon: String,
        tint: Color,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private func openSystemSettings() {
        // System Settings surfaces the extension-approval control (General ›
        // Login Items & Extensions on recent macOS, Privacy & Security on
        // older). Open the app; the exact pane varies by version.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
