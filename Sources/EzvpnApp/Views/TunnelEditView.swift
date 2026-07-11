import SwiftUI
import TunnelCore

/// Add or edit a profile. Reuses the connection fields from the original single
/// screen and adds a required Name. Save validates the name (non-empty, unique)
/// and, on success, dismisses; validation/system errors show inline.
struct TunnelEditView: View {
    enum Mode {
        case add
        case edit(TunnelContainer)
    }

    let mode: Mode
    @EnvironmentObject private var manager: TunnelsManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverNodeID = ""
    @State private var authToken = ""
    @State private var relayURLs = ""
    @State private var routes = ""
    @State private var routes6 = ""
    @State private var dnsServers = ""
    @State private var dnsMatchDomains = ""
    @State private var error: String?
    @State private var saving = false
    @State private var didLoad = false

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var canSave: Bool {
        !trimmed(name).isEmpty
            && !trimmed(serverNodeID).isEmpty
            && !trimmed(authToken).isEmpty
            && !saving
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledField("Name") {
                    TextField("", text: $name)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }

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

            Section {
                LabeledField("IPv4 routes", hint: "comma-separated, optional") {
                    TextField("", text: $routes)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            } header: {
                Text("Split tunnel (IPv4 private CIDRs)")
            } footer: {
                Text("The server gateway is always routed automatically; add CIDRs here to route more.")
            }

            Section("Split tunnel (IPv6 CIDRs)") {
                LabeledField("IPv6 routes", hint: "comma-separated, optional") {
                    TextField("", text: $routes6)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }

            Section {
                LabeledField("DNS servers", hint: "comma-separated IPs, optional") {
                    TextField("", text: $dnsServers)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                LabeledField("Match domains", hint: "comma-separated, optional") {
                    TextField("", text: $dnsMatchDomains)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            } header: {
                Text("Split DNS (conditional forwarding)")
            } footer: {
                Text("Names under the match domains resolve via these DNS servers through the tunnel; everything else keeps the network's normal DNS. Needed because iOS ignores installed DNS profiles while a VPN is connected. Servers should sit inside a tunnel route. Empty match domains send all DNS through the servers.")
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(isAdd ? "New Profile" : "Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard case .edit(let tunnel) = mode, let profile = tunnel.profile else { return }
        name = profile.name
        serverNodeID = profile.serverNodeID
        authToken = profile.authToken
        relayURLs = profile.relayURLs.joined(separator: ", ")
        routes = profile.routes.joined(separator: ", ")
        routes6 = profile.routes6.joined(separator: ", ")
        dnsServers = profile.dnsServers.joined(separator: ", ")
        dnsMatchDomains = profile.dnsMatchDomains.joined(separator: ", ")
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }

        let dnsServerList = splitCSV(dnsServers)
        let dnsMatchDomainList = splitCSV(dnsMatchDomains).map(normalizedDNSMatchDomain)
        if let dnsError = splitDNSValidationError(
            servers: dnsServerList, matchDomains: dnsMatchDomainList
        ) {
            error = dnsError
            return
        }

        // Preserve the stable id on edit; mint a fresh one on add.
        let id: UUID
        if case .edit(let tunnel) = mode, let existing = tunnel.profile {
            id = existing.id
        } else {
            id = UUID()
        }

        let profile = TunnelProfile(
            id: id,
            name: trimmed(name),
            serverNodeID: trimmed(serverNodeID),
            authToken: trimmed(authToken),
            relayURLs: splitCSV(relayURLs),
            routes: splitCSV(routes),
            routes6: splitCSV(routes6),
            dnsServers: dnsServerList,
            dnsMatchDomains: dnsMatchDomainList
        )

        do {
            switch mode {
            case .add:
                try await manager.add(profile)
            case .edit(let tunnel):
                try await manager.modify(tunnel, to: profile)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
