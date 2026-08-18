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
    @EnvironmentObject private var authKeys: AuthKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var form = TunnelProfileForm()
    @State private var error: String?
    @State private var saving = false
    @State private var didLoad = false
    @State private var showingKeys = false
    /// Set when the profile was saved with a key that has since been deleted
    /// from the key list, so the picker comes up empty on purpose.
    @State private var missingKeyNotice: String?

    private var selectedKey: AuthKeyStore.Key? {
        authKeys.key(id: form.authKeyID)
    }

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var canSave: Bool {
        form.hasRequiredFields && !saving
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledField("Name") {
                    TextField("", text: $form.name)
                        .fieldStyle()
                }
            }

            Section("Server") {
                LabeledField("Server node id") {
                    TextField("", text: $form.serverNodeID)
                        .fieldStyle()
                }
                LabeledField("Auth key") {
                    Picker("", selection: $form.authKeyID) {
                        Text(authKeys.keys.isEmpty ? "No keys yet" : "Choose a key…")
                            .tag("")
                        ForEach(authKeys.keys) { key in
                            Text(key.name).tag(key.id)
                        }
                    }
                    .labelsHidden()
                }
                if let key = selectedKey {
                    LabeledField("Public key", hint: "put this on the server") {
                        Text(key.publicKey)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                if let missingKeyNotice {
                    Text(missingKeyNotice)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("Manage keys…") { showingKeys = true }
                LabeledField("Relay URLs", hint: "comma-separated, optional") {
                    TextField("", text: $form.relayURLs)
                        .fieldStyle()
                }
                LabeledField("Relay token", hint: "optional, custom relays only") {
                    SecureField("", text: $form.relayAuthToken)
                        .fieldStyle()
                        .disabled(
                            form.relayURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && form.relayAuthToken.isEmpty
                        )
                }
            }

            Section {
                LabeledField("IPv4 routes", hint: "comma-separated, optional") {
                    TextField("", text: $form.routes)
                        .fieldStyle()
                }
            } header: {
                Text("Split tunnel (IPv4 private CIDRs)")
            } footer: {
                Text("The server gateway is always routed automatically; add CIDRs here to route more.")
            }

            Section("Split tunnel (IPv6 CIDRs)") {
                LabeledField("IPv6 routes", hint: "comma-separated, optional") {
                    TextField("", text: $form.routes6)
                        .fieldStyle()
                }
            }

            #if os(iOS)
            Section {
                LabeledField("DNS servers", hint: "comma-separated IPs, optional") {
                    TextField("", text: $form.dnsServers)
                        .fieldStyle()
                }
                LabeledField("Match domains", hint: "comma-separated, optional") {
                    TextField("", text: $form.dnsMatchDomains)
                        .fieldStyle()
                }
            } header: {
                Text("Split DNS (conditional forwarding)")
            } footer: {
                Text("Names under the match domains resolve via these DNS servers through the tunnel; everything else keeps the network's normal DNS. Needed because iOS ignores installed DNS profiles while a VPN is connected. Servers should sit inside a tunnel route. Empty match domains send all DNS through the servers.")
            }
            #endif

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(isAdd ? "New Profile" : "Edit Profile")
        .inlineNavigationTitle()
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 520)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showingKeys) {
            NavigationStack {
                KeysView()
                    .environmentObject(authKeys)
            }
        }
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard case .edit(let tunnel) = mode else { return }
        guard let profile = tunnel.profile else {
            error = "The saved VPN profile is malformed."
            return
        }
        form = TunnelProfileForm(
            profile: profile,
            relayAuthToken: tunnel.relayAuthToken() ?? ""
        )
        // The profile keeps its own copy of the secret, so a key deleted from
        // the list still connects — but there is nothing to preselect and
        // nothing to re-save with, so say so instead of showing an empty picker
        // with no explanation.
        if !form.authKeyID.isEmpty, selectedKey == nil {
            form.authKeyID = ""
            missingKeyNotice = "The auth key this profile used is no longer in "
                + "the key list. Pick a key before saving."
        }
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }

        // Preserve the stable id on edit; mint a fresh one on add.
        let id: UUID
        if case .edit(let tunnel) = mode {
            id = tunnel.id
        } else {
            id = UUID()
        }

        do {
            #if os(iOS)
            let submission = try form.makeSubmission(id: id, includesDNS: true)
            #else
            let submission = try form.makeSubmission(id: id, includesDNS: false)
            #endif

            // The profile stores only the key's id; its secret is copied into
            // the profile's Keychain item so the tunnel can read it without the
            // key list.
            guard let key = authKeys.key(id: submission.profile.authKeyID) else {
                error = "Pick an auth key for this profile."
                return
            }

            switch mode {
            case .add:
                try await manager.add(
                    submission.profile,
                    authKey: key.secret,
                    relayAuthToken: submission.relayAuthToken
                )
            case .edit(let tunnel):
                try await manager.modify(
                    tunnel,
                    to: submission.profile,
                    authKey: key.secret,
                    relayAuthToken: submission.relayAuthToken
                )
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
