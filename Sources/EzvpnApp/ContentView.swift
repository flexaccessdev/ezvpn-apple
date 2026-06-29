import SwiftUI

struct ContentView: View {
    @StateObject private var vpn = VPNController()

    @State private var serverNodeID = ""
    @State private var alpnToken = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    // Default split-tunnel routes: RFC1918 private ranges only.
    @State private var routes = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
    // IPv6 split-tunnel routes (e.g. the server's ULA prefix). Empty = no IPv6.
    @State private var routes6 = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server node id", text: $serverNodeID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("ALPN token", text: $alpnToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Auth token (required)", text: $authToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Relay URLs (comma-separated, optional)", text: $relayURLs)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Split tunnel (IPv4 private CIDRs)") {
                    TextField("IPv4 routes (comma-separated, optional)", text: $routes)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Split tunnel (IPv6 CIDRs)") {
                    TextField("IPv6 routes (comma-separated, optional)", text: $routes6)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Status") {
                    LabeledContent("State", value: vpn.status)
                    if let err = vpn.lastError {
                        Text(err).foregroundStyle(.red).font(.footnote)
                    }
                }
                Section {
                    Button("Connect") {
                        Task { await vpn.connect(currentSettings()) }
                    }
                    .disabled(serverNodeID.isEmpty || alpnToken.isEmpty || authToken.isEmpty)

                    Button("Disconnect", role: .destructive) {
                        vpn.disconnect()
                    }
                }
            }
            .navigationTitle("ezvpn")
        }
    }

    private func currentSettings() -> VPNController.Settings {
        VPNController.Settings(
            serverNodeID: serverNodeID.trimmingCharacters(in: .whitespaces),
            alpnToken: alpnToken.trimmingCharacters(in: .whitespaces),
            authToken: authToken.trimmingCharacters(in: .whitespaces),
            relayURLs: splitCSV(relayURLs),
            routes: splitCSV(routes),
            routes6: splitCSV(routes6)
        )
    }

    private func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    ContentView()
}
