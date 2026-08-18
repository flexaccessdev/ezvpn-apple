import Foundation
import Security
@testable import ezvpn

/// In-memory stand-in for the Keychain, shared by the tests that exercise
/// `AuthKeyKeychain` and `AuthKeyStore`. Models just enough of the real
/// behavior to be useful: add/update/copy/delete keyed by (service, account),
/// plus persistent-reference lookup (the iOS extension's path).
///
/// Keep the instance alive for as long as its `client` is used: the client's
/// closures capture it `unowned`, so `InMemoryAuthKeyKeychain().client` alone
/// traps the moment the first query runs.
final class InMemoryAuthKeyKeychain {
    private struct Item {
        var secretData: Data
        let persistentReference: Data
    }

    // Keyed by (service, account) so a single profile id can hold both the
    // auth-key and relay-token secrets at once, like the real Keychain.
    private var items: [String: Item] = [:]

    private func storageKey(service: String?, account: String) -> String {
        "\(service ?? AuthKeyKeychain.service)\u{0}\(account)"
    }

    var client: AuthKeyKeychainClient {
        AuthKeyKeychainClient(
            add: { [unowned self] query in add(query) },
            update: { [unowned self] query, attributes in
                update(query, attributes: attributes)
            },
            copyMatching: { [unowned self] query in copyMatching(query) },
            delete: { [unowned self] query in delete(query) }
        )
    }

    private func add(_ query: [String: Any]) -> AuthKeyKeychainClient.Result {
        guard
            let account = query[kSecAttrAccount as String] as? String,
            let secretData = query[kSecValueData as String] as? Data
        else {
            return (errSecParam, nil)
        }
        let key = storageKey(service: query[kSecAttrService as String] as? String, account: account)
        guard items[key] == nil else {
            return (errSecDuplicateItem, nil)
        }

        let reference = Data("persistent-ref:\(key)".utf8)
        items[key] = Item(
            secretData: secretData,
            persistentReference: reference
        )
        return (errSecSuccess, reference)
    }

    private func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        guard
            let account = query[kSecAttrAccount as String] as? String,
            let secretData = attributes[kSecValueData as String] as? Data
        else {
            return errSecItemNotFound
        }
        let key = storageKey(service: query[kSecAttrService as String] as? String, account: account)
        guard var item = items[key] else {
            return errSecItemNotFound
        }

        item.secretData = secretData
        items[key] = item
        return errSecSuccess
    }

    private func copyMatching(
        _ query: [String: Any]
    ) -> AuthKeyKeychainClient.Result {
        // Identity query (class + service + account): return the ref or the
        // data, mirroring the real Keychain's kSecReturn* handling. A query
        // with the right account but a mismatched service or class matches
        // nothing.
        if let account = query[kSecAttrAccount as String] as? String {
            let classMatches =
                (query[kSecClass as String] as? String) == (kSecClassGenericPassword as String)
            let key = storageKey(
                service: query[kSecAttrService as String] as? String, account: account)
            guard classMatches, let item = items[key] else {
                return (errSecItemNotFound, nil)
            }
            if query[kSecReturnPersistentRef as String] as? Bool == true {
                return (errSecSuccess, item.persistentReference)
            }
            return (errSecSuccess, item.secretData)
        }

        // Persistent-reference query (the iOS extension's path).
        let reference = query[kSecValuePersistentRef as String] as? Data
        guard
            let reference,
            let item = items.values.first(where: {
                $0.persistentReference == reference
            })
        else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, item.secretData)
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        let key = storageKey(service: query[kSecAttrService as String] as? String, account: account)
        return items.removeValue(forKey: key) == nil
            ? errSecItemNotFound
            : errSecSuccess
    }
}
