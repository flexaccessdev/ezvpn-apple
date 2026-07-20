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

    @State private var form = TunnelProfileForm()
    @State private var error: String?
    @State private var saving = false
    @State private var didLoad = false

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
                LabeledField("Auth token") {
                    SecureField("", text: $form.authToken)
                        .fieldStyle()
                }
                LabeledField("Relay URLs", hint: "comma-separated, optional") {
                    TextField("", text: $form.relayURLs)
                        .fieldStyle()
                }
                LabeledField("Relay token", hint: "optional, custom relays only") {
                    SecureField("", text: $form.relayAuthToken)
                        .fieldStyle()
                        .disabled(
                            form.relayURLs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .onAppear(perform: loadIfNeeded)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard case .edit(let tunnel) = mode else { return }
        do {
            guard let profile = tunnel.profile else {
                error = "The saved VPN profile is malformed."
                return
            }
            form = TunnelProfileForm(
                profile: profile,
                authToken: try tunnel.authToken(),
                relayAuthToken: tunnel.relayAuthToken() ?? ""
            )
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
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

            switch mode {
            case .add:
                try await manager.add(
                    submission.profile,
                    authToken: submission.authToken,
                    relayAuthToken: submission.relayAuthToken
                )
            case .edit(let tunnel):
                try await manager.modify(
                    tunnel,
                    to: submission.profile,
                    authToken: submission.authToken,
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
