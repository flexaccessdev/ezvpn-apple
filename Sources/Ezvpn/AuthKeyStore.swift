import Combine
import Foundation
import Security
import TunnelCore

/// The app's shared, named client auth keys — the same model the desktop and
/// the flextunnel apps use: one list of keypairs that profiles reference by id,
/// so several profiles (or several servers) can authenticate with one device
/// identity instead of pasting the same secret into each.
///
/// The whole list persists as one JSON blob in the Keychain item
/// `AuthKeyKeychain.keyListService`: the names ride along with the secrets (they
/// aren't sensitive, but one storage home keeps the list atomic), and the public
/// halves are never stored — each is re-derived from its secret via the FFI on
/// load. The tunnel never reads this list; saving a profile copies the selected
/// key's secret into that profile's own Keychain item, which is what the
/// packet-tunnel provider resolves (see `AuthKeyKeychain`).
@MainActor
final class AuthKeyStore: ObservableObject {
    /// One named keypair. `publicKey` is derived, not persisted.
    struct Key: Identifiable, Equatable {
        let id: String
        var name: String
        var secret: String
        var publicKey: String
    }

    /// A user-facing failure: the name rules, an invalid or duplicate secret,
    /// or a Keychain write that didn't land.
    struct ValidationError: Error {
        let message: String
    }

    /// The persisted shape: everything but the derived public half.
    private struct StoredKey: Codable {
        var id: String
        var name: String
        var secret: String
    }

    @Published private(set) var keys: [Key] = []

    private let client: AuthKeyKeychainClient

    /// Why the stored list couldn't be read, or nil once it was (an absent
    /// item counts: a fresh install genuinely has no keys). While this is set
    /// the list on screen is not what's stored, so every write is refused —
    /// persisting would replace the real list with this partial view.
    private let loadError: ValidationError?

    init(client: AuthKeyKeychainClient = .security) {
        self.client = client
        switch Self.loadStored(client: client) {
        case .success(let stored):
            loadError = nil
            // A record whose secret no longer derives a public key is corrupt —
            // drop it rather than carry an entry that can never connect.
            keys = stored.compactMap { record in
                AuthKey.publicKey(forSecret: record.secret).map {
                    Key(id: record.id, name: record.name, secret: record.secret, publicKey: $0)
                }
            }
            // Make the pruning stick, so a corrupt record doesn't sit in the
            // Keychain until the next add/rename/delete happens to rewrite it.
            // Nothing to surface this early — a failed write just leaves it there.
            if keys.count != stored.count { persist() }
        case .failure(let error):
            loadError = error
        }
    }

    /// Read the persisted list. Only an absent Keychain item means "no keys
    /// yet"; a Keychain failure or undecodable JSON is a load failure, which
    /// must never pass as an empty list — the next write would then overwrite
    /// every stored key with nothing.
    private static func loadStored(
        client: AuthKeyKeychainClient
    ) -> Result<[StoredKey], ValidationError> {
        let json: String
        do {
            json = try AuthKeyKeychain.secret(
                account: AuthKeyKeychain.keyListAccount,
                service: AuthKeyKeychain.keyListService,
                client: client)
        } catch AuthKeyKeychainError.security(_, errSecItemNotFound) {
            return .success([])
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .failure(.init(
                message: "Couldn't read the key list from the Keychain: \(detail) "
                    + "Keys can't be changed until it can be read."))
        }
        guard
            let data = json.data(using: .utf8),
            let stored = try? JSONDecoder().decode([StoredKey].self, from: data)
        else {
            return .failure(.init(
                message: "The stored key list couldn't be decoded. "
                    + "Keys can't be changed until it can be read."))
        }
        return .success(stored)
    }

    func key(id: String) -> Key? {
        keys.first { $0.id == id }
    }

    /// Validate and add a key: the name follows the same rules as a profile
    /// name (trimmed, required, unique case-insensitively) and the secret must
    /// parse. The same keypair twice under two names is an accidental re-add,
    /// not a use case.
    @discardableResult
    func add(name rawName: String, secret rawSecret: String) -> Result<Key, ValidationError> {
        let name: String
        switch validated(name: rawName, excluding: nil) {
        case .success(let valid): name = valid
        case .failure(let error): return .failure(error)
        }
        let secret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicKey = AuthKey.publicKey(forSecret: secret) else {
            return .failure(.init(message: "Not a valid secret key (expected ed25519-sec:…)."))
        }
        if let other = keys.first(where: { $0.publicKey == publicKey }) {
            return .failure(.init(message: "Key \"\(other.name)\" already holds this secret."))
        }
        let key = Key(id: UUID().uuidString, name: name, secret: secret, publicKey: publicKey)
        keys.append(key)
        // A failed write means the key would vanish on relaunch — roll the list
        // back so what's on screen is what's actually stored, and say so.
        if let error = persist() {
            keys.removeLast()
            return .failure(error)
        }
        return .success(key)
    }

    /// Rename `id`; returns a user-facing error when the new name is invalid.
    func rename(id: String, to newName: String) -> ValidationError? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return nil }
        switch validated(name: newName, excluding: id) {
        case .success(let name):
            let previous = keys[index].name
            keys[index].name = name
            if let error = persist() {
                keys[index].name = previous
                return error
            }
            return nil
        case .failure(let error):
            return error
        }
    }

    /// Delete `id`; returns a user-facing error when the removal couldn't be
    /// written back (the key stays listed then, since it's still stored).
    ///
    /// Profiles already saved with this key keep working: their own Keychain
    /// copy of the secret is what connects. Deleting here only removes the key
    /// from the list the editor picks from.
    func delete(id: String) -> ValidationError? {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = keys.remove(at: index)
        if let error = persist() {
            keys.insert(removed, at: index)
            return error
        }
        return nil
    }

    /// Validate a name with the profile-name rules (trimmed, non-empty, unique
    /// ignoring case/diacritics/width), rejecting duplicates of any key but
    /// `own`.
    private func validated(
        name raw: String, excluding own: String?
    ) -> Result<String, ValidationError> {
        let others = keys.filter { $0.id != own }.map(\.name)
        switch validateTunnelName(raw, existing: others) {
        case .success(let name):
            return .success(name)
        case .failure(.empty):
            return .failure(.init(message: "Key name is required."))
        case .failure(.duplicate):
            return .failure(.init(message: "Another key is already named that."))
        }
    }

    /// Write the whole list back to the Keychain, returning a user-facing
    /// error when it didn't land — a silently dropped write would lose keys
    /// at the next launch.
    @discardableResult
    private func persist() -> ValidationError? {
        // Never write over a list that couldn't be read: what's in memory is a
        // partial view of it, so add/rename/delete would destroy stored keys.
        // Returning the load error rolls each of those back with the reason.
        if let loadError { return loadError }
        let stored = keys.map { StoredKey(id: $0.id, name: $0.name, secret: $0.secret) }
        guard
            let data = try? JSONEncoder().encode(stored),
            let json = String(data: data, encoding: .utf8)
        else {
            return .init(message: "Couldn't encode the key list.")
        }
        do {
            _ = try AuthKeyKeychain.store(
                json,
                account: AuthKeyKeychain.keyListAccount,
                service: AuthKeyKeychain.keyListService,
                client: client)
            return nil
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .init(message: "Couldn't save the key list to the Keychain: \(detail)")
        }
    }
}
