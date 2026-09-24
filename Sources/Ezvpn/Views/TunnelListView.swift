import SwiftUI
import TunnelCore

/// Root screen: the list of saved VPN profiles (WireGuard-app style). Tap a row
/// to see its detail; toggle a row to connect/disconnect; `+` adds a profile.
struct TunnelListView: View {
    @EnvironmentObject private var manager: TunnelsManager
    @EnvironmentObject private var authKeys: AuthKeyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAdd = false
    @State private var showingKeys = false

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
                // The auth keys are shared across profiles, so they are managed
                // from the root screen (and from the profile editor's picker),
                // not per profile.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingKeys = true
                    } label: {
                        Label("Auth keys", systemImage: "key")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add profile", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                NavigationStack {
                    TunnelEditView(mode: .add)
                        .environmentObject(authKeys)
                }
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack {
                    KeysView()
                        .environmentObject(authKeys)
                }
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
            .safeAreaInset(edge: .top, spacing: 0) {
                ExtensionVersionBanner(check: manager.runningExtensionCheck)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VersionFooter()
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

/// Warns when the connected tunnel runs an extension build other than this
/// app's — the system has not replaced the old extension yet, so the tunnel
/// still has the old code. Renders nothing on a match or with no tunnel up.
private struct ExtensionVersionBanner: View {
    @EnvironmentObject private var manager: TunnelsManager
    let check: ExtensionVersionCheck?

    var body: some View {
        if case .mismatch(let running) = check {
            NoticeBanner(
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                tint: .orange,
                message: ExtensionVersionBanner.message(running: running),
                actionTitle: actionTitle,
                action: action)
        }
    }

    static func message(running: BundleVersion?) -> String {
        let runningText = running.map { "is \($0)" } ?? "is older"
        #if os(macOS)
        let remedy = "Update the extension; if this persists, restart your Mac."
        #else
        let remedy = "Disconnect, then quit and reopen ezvpn."
        #endif
        return "The running tunnel extension \(runningText), but this app is "
            + "\(AppVersion.appNumber). \(remedy)"
    }

    #if os(macOS)
    private var actionTitle: String? { "Update extension" }
    private var action: (() -> Void)? { { manager.reactivateSystemExtension() } }
    #else
    private var actionTitle: String? { nil }
    private var action: (() -> Void)? { nil }
    #endif
}

/// A full-width tinted notice with an optional link-style action, shown at the
/// top of the profile list.
struct NoticeBanner: View {
    let icon: String
    let tint: Color
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                #if os(macOS)
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                #else
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                #endif
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
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
            NoticeBanner(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                message: "Allow the ezvpn network extension in System Settings "
                    + "to enable the VPN.",
                actionTitle: "Open System Settings",
                action: openSystemSettings)
        case .failed(let detail):
            NoticeBanner(
                icon: "xmark.octagon.fill",
                tint: .red,
                message: "Couldn't install the network extension: \(detail)",
                actionTitle: nil,
                action: nil)
        case .idle, .activating, .active:
            EmptyView()
        }
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
