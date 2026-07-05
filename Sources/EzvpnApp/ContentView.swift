import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpn = VPNController()

    // Persisted as typed (like flextunnel) so the field survives a relaunch
    // even before the first successful connect saves a VPN configuration.
    @AppStorage("lastServerNodeID") private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    // IPv4 split-tunnel routes (e.g. "10.0.0.0/8"). Empty = no IPv4 routing.
    @State private var routes = ""
    // IPv6 split-tunnel routes (e.g. the server's ULA prefix). Empty = no IPv6.
    @State private var routes6 = ""
    @State private var didPrefill = false

    // Reload preferences when returning to the foreground: status/config
    // notifications can be missed while the app is suspended.
    @Environment(\.scenePhase) private var scenePhase

    private var isConnecting: Bool {
        vpn.status == .connecting || vpn.status == .reasserting
    }

    /// The tunnel session is doing anything at all — the form describes the
    /// running configuration, so editing is locked until it fully stops.
    private var isActive: Bool {
        switch vpn.status {
        case .connected, .connecting, .reasserting, .disconnecting: return true
        case .invalid, .disconnected: return false
        @unknown default: return false
        }
    }

    private var canConnect: Bool {
        !trimmed(serverNodeID).isEmpty
            && !trimmed(authToken).isEmpty
            && !isActive
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledField("Server node id") {
                        TextField("", text: $serverNodeID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Auth token") {
                        SecureField("", text: $authToken)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    LabeledField("Relay URLs", hint: "comma-separated, optional") {
                        TextField("", text: $relayURLs)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                .disabled(isActive)

                Section("Split tunnel (IPv4 private CIDRs)") {
                    LabeledField("IPv4 routes", hint: "comma-separated, optional") {
                        TextField("", text: $routes)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                .disabled(isActive)

                Section("Split tunnel (IPv6 CIDRs)") {
                    LabeledField("IPv6 routes", hint: "comma-separated, optional") {
                        TextField("", text: $routes6)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                .disabled(isActive)

                Section("Status") {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(vpn.status.indicatorColor)
                            .frame(width: 10, height: 10)
                        Text(vpn.status.displayText)
                        Spacer()
                        if vpn.status == .connected, let since = vpn.connectedDate {
                            Text(since, style: .relative)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let err = vpn.lastError {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    if isConnecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(vpn.status == .reasserting
                                ? "Reconnecting…" : "Connecting…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { vpn.disconnect() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else if isActive {
                        Button("Disconnect", role: .destructive) {
                            vpn.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(vpn.status == .disconnecting)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        Button("Connect") {
                            Task { await vpn.connect(currentSettings()) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(!canConnect)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("ezvpn")
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vpn.savedSettings) { _, saved in
                prefillIfNeeded(from: saved)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await vpn.reload() }
                }
            }
            .onAppear {
                prefillIfNeeded(from: vpn.savedSettings)
            }
        }
    }

    /// Prefill the form once from the configuration saved in VPN preferences,
    /// so relaunching the app shows what the system will actually run. Fields
    /// the user has already typed into win over the stored values.
    private func prefillIfNeeded(from saved: VPNController.Settings?) {
        guard !didPrefill, let saved else { return }
        didPrefill = true
        if serverNodeID.isEmpty { serverNodeID = saved.serverNodeID }
        if authToken.isEmpty { authToken = saved.authToken }
        if relayURLs.isEmpty { relayURLs = saved.relayURLs.joined(separator: ", ") }
        if routes.isEmpty { routes = saved.routes.joined(separator: ", ") }
        if routes6.isEmpty { routes6 = saved.routes6.joined(separator: ", ") }
    }

    private func currentSettings() -> VPNController.Settings {
        VPNController.Settings(
            serverNodeID: trimmed(serverNodeID),
            authToken: trimmed(authToken),
            relayURLs: splitCSV(relayURLs),
            routes: splitCSV(routes),
            routes6: splitCSV(routes6)
        )
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension NEVPNStatus {
    var displayText: String {
        switch self {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        case .invalid, .disconnected: return Color(.systemGray3)
        @unknown default: return Color(.systemGray3)
        }
    }
}

/// A form row whose label stays visible above the field even after the field
/// has content — unlike a placeholder, which disappears once the user types.
private struct LabeledField<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
