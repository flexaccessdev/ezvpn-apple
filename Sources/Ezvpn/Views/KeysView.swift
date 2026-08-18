import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

/// The auth-key manager: the app's shared, named ed25519 keys, with generate,
/// import (paste a secret from another device), rename, copy, and delete.
/// Profiles pick one of these in the editor; a key's public half goes on the
/// server's authorized_keys file. Public keys show unmasked (they are not
/// secrets); secrets never render — export copies straight to the clipboard,
/// behind a confirmation.
///
/// The body is assembled from small pieces (`keyList`, `toolbarContent`, and
/// the two alert groups): one flat chain of every alert and dialog is more than
/// the SwiftUI type checker will take.
struct KeysView: View {
    @EnvironmentObject private var store: AuthKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingGenerate = false
    @State private var showingImport = false
    @State private var renameTarget: AuthKeyStore.Key?
    @State private var exportTarget: AuthKeyStore.Key?
    @State private var deleteTarget: AuthKeyStore.Key?
    @State private var nameField = ""
    @State private var secretField = ""
    @State private var errorMessage: String?

    var body: some View {
        keyActionDialogs(addKeyAlerts(keyList))
    }

    @ViewBuilder
    private var keyList: some View {
        Group {
            if store.keys.isEmpty {
                ContentUnavailableView {
                    Label("No auth keys", systemImage: "key")
                } description: {
                    Text(Self.emptyDescription)
                }
            } else {
                List {
                    Section {
                        ForEach(store.keys) { key in
                            row(key)
                        }
                    } footer: {
                        Text(Self.listFooter)
                    }
                }
            }
        }
        .navigationTitle("Auth Keys")
        .inlineNavigationTitle()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    nameField = ""
                    showingGenerate = true
                } label: {
                    Label("Generate New Key…", systemImage: "key")
                }
                Button {
                    nameField = ""
                    secretField = ""
                    showingImport = true
                } label: {
                    Label("Enter Existing Key…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("Add key", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }

    /// The two "add a key" prompts.
    private func addKeyAlerts<Content: View>(_ content: Content) -> some View {
        content
            .alert("Name the new key", isPresented: $showingGenerate) {
                TextField("e.g. this mac", text: $nameField)
                Button("Generate") { generateKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Names only exist in this app's key list.")
            }
            .alert("Enter existing key", isPresented: $showingImport) {
                TextField("Name (e.g. work laptop)", text: $nameField)
                SecureField("ed25519-sec:…", text: $secretField)
                Button("Add Key") { importKey() }
                Button("Cancel", role: .cancel) { secretField = "" }
            } message: {
                Text(Self.importHelp)
            }
    }

    /// Per-key actions (rename, copy the secret, delete) plus the shared error
    /// alert they report through.
    private func keyActionDialogs<Content: View>(_ content: Content) -> some View {
        content
            .alert(
                "Rename key", isPresented: presented($renameTarget), presenting: renameTarget
            ) { key in
                TextField("Name", text: $nameField)
                Button("Rename") {
                    if let error = store.rename(id: key.id, to: nameField) {
                        errorMessage = error.message
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("")
            }
            .confirmationDialog(
                "Copy the secret key?",
                isPresented: presented($exportTarget),
                titleVisibility: .visible,
                presenting: exportTarget
            ) { key in
                Button("Copy Secret Key") { Clipboard.copy(key.secret, isSecret: true) }
            } message: { key in
                Text("Anyone holding the secret key can connect as \"\(key.name)\". "
                    + "Paste it into another device's key import.")
            }
            .confirmationDialog(
                "Delete this key?",
                isPresented: presented($deleteTarget),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { key in
                Button("Delete \"\(key.name)\"", role: .destructive) {
                    if let error = store.delete(id: key.id) {
                        errorMessage = error.message
                    }
                }
            } message: { _ in
                Text(Self.deleteWarning)
            }
            .alert(
                "Can't do that", isPresented: presented($errorMessage), presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private func row(_ key: AuthKeyStore.Key) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                Text(key.publicKey)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            rowMenu(key)
        }
        .padding(.vertical, 2)
    }

    private func rowMenu(_ key: AuthKeyStore.Key) -> some View {
        Menu {
            Button {
                Clipboard.copy(key.publicKey)
            } label: {
                Label("Copy Public Key", systemImage: "doc.on.doc")
            }
            Button {
                exportTarget = key
            } label: {
                Label("Copy Secret Key…", systemImage: "square.and.arrow.up")
            }
            Button {
                nameField = key.name
                renameTarget = key
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = key
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Actions for \(key.name)")
        }
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func generateKey() {
        guard let pair = AuthKey.generate() else {
            errorMessage = "Key generation failed."
            return
        }
        report(store.add(name: nameField, secret: pair.secretKey))
    }

    private func importKey() {
        let secret = secretField
        secretField = ""
        report(store.add(name: nameField, secret: secret))
    }

    private func report(_ result: Result<AuthKeyStore.Key, AuthKeyStore.ValidationError>) {
        if case .failure(let error) = result {
            errorMessage = error.message
        }
    }

    /// A presence binding for `.alert`/`.confirmationDialog(presenting:)`:
    /// true while the optional holds a value; dismissal clears it.
    private func presented<T>(_ target: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { target.wrappedValue != nil },
            set: { if !$0 { target.wrappedValue = nil } }
        )
    }

    private static let emptyDescription = """
        Generate a key (or paste one from another device), then put its public \
        key on the server's authorized_keys file.
        """

    private static let listFooter = """
        A profile authenticates with the key it selects. Deleting a key here \
        doesn't disconnect profiles already saved with it — re-save a profile \
        to change the key it uses.
        """

    private static let importHelp = """
        Paste a secret key generated elsewhere — copied from another device, or \
        by "flexaccess-keys generate-auth-key" — to reuse its identity.
        """

    private static let deleteWarning = """
        The secret key is removed from this device's key list. The server keeps \
        trusting its public key until that's taken off the authorized_keys file.
        """
}

/// The one clipboard call the key screen needs, per platform. Secrets are
/// copied with an expiry on iOS so the most sensitive thing the app holds
/// doesn't sit on a pasteboard every foregrounded app can read until something
/// else replaces it. macOS has no expiring pasteboard.
enum Clipboard {
    static func copy(_ value: String, isSecret: Bool = false) {
        #if os(iOS)
        if isSecret {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: value]],
                options: [.expirationDate: Date().addingTimeInterval(secretLifetime)])
        } else {
            UIPasteboard.general.string = value
        }
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    /// Long enough to reach for the other device and paste, short enough that a
    /// forgotten copy doesn't linger.
    private static var secretLifetime: TimeInterval { 5 * 60 }
}
