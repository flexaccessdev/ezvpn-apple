import Foundation
import Security

/// Keys for the transient `startTunnel(options:)` dictionary the app passes to
/// the provider. Options travel in memory through the NE session — never
/// persisted by the system — which makes them the delivery channel for the
/// auth key on macOS (see the daemon storage note in AuthKeyKeychain).
enum TunnelStartOption {
    static let authKey = "ezvpn.auth-key"
    static let relayAuthToken = "ezvpn.relay-auth-token"
}

struct AuthKeyKeychainClient {
    typealias Result = (status: OSStatus, value: Any?)

    let add: ([String: Any]) -> Result
    let update: ([String: Any], [String: Any]) -> OSStatus
    let copyMatching: ([String: Any]) -> Result
    let delete: ([String: Any]) -> OSStatus

    static let security = AuthKeyKeychainClient(
        add: { query in
            var result: CFTypeRef?
            let status = SecItemAdd(query as CFDictionary, &result)
            return (status, result)
        },
        update: { query, attributes in
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        },
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    )
}

/// Keychain storage for the app's secrets: the client's ed25519 auth key
/// (`ed25519-sec:…`), the optional shared relay bearer token, and the app's
/// named key list.
///
/// The containing app creates and updates a data-protection Keychain item. On
/// iOS, the packet-tunnel extension resolves the persistent reference stored in
/// `NETunnelProviderProtocol.passwordReference`; both targets carry the same
/// keychain-access-group entitlement. On macOS, the root system extension
/// cannot access the user's data-protection Keychain, so the app passes the
/// secret in start options and the provider keeps a separate System-keychain
/// copy for OS-initiated restarts.
enum AuthKeyKeychain {
    /// Keychain service for the per-profile auth key — the ed25519 secret key
    /// the client authenticates the handshake with. Account: the profile id, so
    /// each profile carries the secret of whichever named key it selected.
    static let service = "ezvpn.auth-key"
    /// Keychain service for the optional shared relay bearer token. A distinct
    /// service lets a single profile id hold both secrets side by side.
    static let relayService = "ezvpn.relay-auth-token"
    /// Keychain service for the app's named auth-key list — one JSON blob of
    /// {id, name, secret} records under a single fixed account (see
    /// `AuthKeyStore`). App-side only; the tunnel never reads the list, it
    /// reads the per-profile copy under `service`.
    static let keyListService = "ezvpn.auth-keys"
    /// The single account the key list lives under (there is only ever one).
    static let keyListAccount = "shared"
    static let accessGroupInfoKey = "EZVPNKeychainAccessGroup"

    /// Store `secret` under `service`/`account`, returning the item's
    /// persistent reference (what an `NETunnelProviderProtocol` carries as its
    /// `passwordReference`).
    static func store(
        _ secret: String,
        account: String,
        service: String,
        client: AuthKeyKeychainClient = .security
    ) throws -> Data {
        guard !secret.isEmpty, let secretData = secret.data(using: .utf8) else {
            throw AuthKeyKeychainError.invalidSecret
        }

        var addQuery = try identityQuery(account: account, service: service)
        addQuery[kSecValueData as String] = secretData
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecReturnPersistentRef as String] = true

        let (addStatus, result) = client.add(addQuery)
        switch addStatus {
        case errSecSuccess:
            guard let reference = result as? Data else {
                throw AuthKeyKeychainError.missingPersistentReference
            }
            return reference
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: secretData,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = client.update(
                try identityQuery(account: account, service: service), attributes)
            guard updateStatus == errSecSuccess else {
                throw AuthKeyKeychainError.security(
                    operation: "update auth key", status: updateStatus)
            }
            return try persistentReference(
                account: account, service: service, client: client)
        default:
            throw AuthKeyKeychainError.security(
                operation: "store auth key", status: addStatus)
        }
    }

    /// Per-profile flavor of `store(_:account:service:)`: the account is the
    /// profile id, so every profile keeps its own copy of the selected key's
    /// secret (and, under `relayService`, its relay token).
    @discardableResult
    static func store(
        _ secret: String,
        for profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws -> Data {
        try store(
            secret, account: profileID.uuidString, service: service, client: client)
    }

    #if os(iOS)
    /// iOS-only: resolve the secret through the `passwordReference` persistent
    /// ref stored on the `NETunnelProviderProtocol`. The ref already encodes
    /// the item's identity and access group. Adding kSecClass,
    /// kSecAttrAccessGroup, kSecMatchLimit, or kSecUseDataProtectionKeychain
    /// alongside kSecValuePersistentRef makes SecItemCopyMatching fail with
    /// errSecParam (-50, "one or more parameters passed to a function were
    /// not valid").
    static func secret(
        for persistentReference: Data,
        client: AuthKeyKeychainClient = .security
    ) throws -> String {
        try decodeSecret(client.copyMatching([
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnData as String: true,
        ]))
    }
    #endif

    /// Resolve a secret by item identity (service + account + access group) in
    /// the data-protection keychain. This is the app-side lookup only: it runs
    /// in the user context, where the data-protection keychain is available.
    /// The packet-tunnel system extension runs as a root daemon with no user
    /// context and cannot read the data-protection keychain; it must use
    /// daemonSecret(for:) against the System keychain instead (see the
    /// daemon-side storage section below).
    static func secret(
        account: String,
        service: String,
        client: AuthKeyKeychainClient = .security
    ) throws -> String {
        var query = try identityQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try decodeSecret(client.copyMatching(query))
    }

    /// Per-profile flavor of `secret(account:service:)`.
    static func secret(
        forProfileID profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws -> String {
        try secret(
            account: profileID.uuidString, service: service, client: client)
    }

    #if os(macOS)
    // MARK: Daemon-side storage (packet-tunnel system extension)
    //
    // The system extension runs as a root launchd daemon. The data-protection
    // keychain only exists in a user context (there is no secd to talk to,
    // and the user's items belong to the user's keybag), so the identity
    // queries above cannot work there. Daemons default to the legacy System
    // keychain (/Library/Keychains/System.keychain), which root reads and
    // writes without user interaction on macOS 14+. The app therefore hands
    // the auth key to the provider in the tunnel-start options
    // (TunnelStartOption.authKey); the provider persists it here so
    // system-initiated restarts (reboot, crash recovery) can still connect.
    // No kSecUseDataProtectionKeychain and no kSecAttrAccessGroup: both are
    // data-protection-keychain concepts.

    static func persistDaemonSecret(
        _ secret: String,
        for profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws {
        guard !secret.isEmpty, let secretData = secret.data(using: .utf8) else {
            throw AuthKeyKeychainError.invalidSecret
        }
        var addQuery = daemonIdentityQuery(for: profileID, service: service)
        addQuery[kSecValueData as String] = secretData

        let (status, _) = client.add(addQuery)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = client.update(
                daemonIdentityQuery(for: profileID, service: service),
                [kSecValueData as String: secretData])
            guard updateStatus == errSecSuccess else {
                throw AuthKeyKeychainError.security(
                    operation: "update daemon auth key", status: updateStatus)
            }
        default:
            throw AuthKeyKeychainError.security(
                operation: "store daemon auth key", status: status)
        }
    }

    static func daemonSecret(
        for profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws -> String {
        var query = daemonIdentityQuery(for: profileID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try decodeSecret(client.copyMatching(query))
    }

    /// macOS daemon-side delete against the System keychain (mirror of the
    /// data-protection `delete(for:service:)`). Used to clear the optional relay
    /// token when it is removed from a profile.
    static func deleteDaemonSecret(
        for profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws {
        let status = client.delete(daemonIdentityQuery(for: profileID, service: service))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthKeyKeychainError.security(
                operation: "delete daemon auth key", status: status)
        }
    }

    private static func daemonIdentityQuery(
        for profileID: UUID, service: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }
    #endif

    private static func decodeSecret(
        _ result: AuthKeyKeychainClient.Result
    ) throws -> String {
        guard result.status == errSecSuccess else {
            throw AuthKeyKeychainError.security(
                operation: "load auth key", status: result.status)
        }
        guard
            let data = result.value as? Data,
            let secret = String(data: data, encoding: .utf8),
            !secret.isEmpty
        else {
            throw AuthKeyKeychainError.invalidSecret
        }
        return secret
    }

    static func delete(
        account: String,
        service: String,
        client: AuthKeyKeychainClient = .security
    ) throws {
        let status = client.delete(try identityQuery(account: account, service: service))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthKeyKeychainError.security(
                operation: "delete auth key", status: status)
        }
    }

    /// Per-profile flavor of `delete(account:service:)`.
    static func delete(
        for profileID: UUID,
        service: String = AuthKeyKeychain.service,
        client: AuthKeyKeychainClient = .security
    ) throws {
        try delete(
            account: profileID.uuidString, service: service, client: client)
    }

    private static func persistentReference(
        account: String,
        service: String,
        client: AuthKeyKeychainClient
    ) throws -> Data {
        var query = try identityQuery(account: account, service: service)
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = client.copyMatching(query)
        guard status == errSecSuccess else {
            throw AuthKeyKeychainError.security(
                operation: "load auth key reference", status: status)
        }
        guard let reference = result as? Data else {
            throw AuthKeyKeychainError.missingPersistentReference
        }
        return reference
    }

    private static func identityQuery(
        account: String, service: String
    ) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: try accessGroup(),
            // Required on macOS for access-group and accessibility attributes
            // to use the data-protection Keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func accessGroup() throws -> String {
        guard
            let accessGroup = Bundle.main.object(
                forInfoDictionaryKey: accessGroupInfoKey
            ) as? String,
            !accessGroup.isEmpty,
            !accessGroup.contains("$(")
        else {
            throw AuthKeyKeychainError.missingAccessGroup
        }
        return accessGroup
    }
}

enum AuthKeyKeychainError: LocalizedError {
    case missingAccessGroup
    case missingPersistentReference
    case invalidSecret
    case security(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessGroup:
            return "The shared Keychain access group is not configured."
        case .missingPersistentReference:
            return "The Keychain did not return an auth-key reference."
        case .invalidSecret:
            return "The Keychain auth key is empty or invalid."
        case .security(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            return "Could not \(operation): \(detail)."
        }
    }
}
