import Foundation
import Security

/// Keys for the transient `startTunnel(options:)` dictionary the app passes to
/// the provider. Options travel in memory through the NE session — never
/// persisted by the system — which makes them the delivery channel for the
/// auth token on macOS (see the daemon storage note in AuthTokenKeychain).
enum TunnelStartOption {
    static let authToken = "ezvpn.auth-token"
    static let relayAuthToken = "ezvpn.relay-auth-token"
}

struct AuthTokenKeychainClient {
    typealias Result = (status: OSStatus, value: Any?)

    let add: ([String: Any]) -> Result
    let update: ([String: Any], [String: Any]) -> OSStatus
    let copyMatching: ([String: Any]) -> Result
    let delete: ([String: Any]) -> OSStatus

    static let security = AuthTokenKeychainClient(
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

/// Keychain storage for profile authentication tokens.
///
/// The containing app creates and updates a data-protection Keychain item. On
/// iOS, the packet-tunnel extension resolves the persistent reference stored in
/// `NETunnelProviderProtocol.passwordReference`; both targets carry the same
/// keychain-access-group entitlement. On macOS, the root system extension
/// cannot access the user's data-protection Keychain, so the app passes the
/// token in start options and the provider keeps a separate System-keychain
/// copy for OS-initiated restarts.
enum AuthTokenKeychain {
    /// Keychain service for the per-server auth token (the required client
    /// credential presented to the VPN server).
    static let service = "ezvpn.auth-token"
    /// Keychain service for the optional shared relay bearer token. A distinct
    /// service lets a single profile id hold both secrets side by side.
    static let relayService = "ezvpn.relay-auth-token"
    static let accessGroupInfoKey = "EZVPNKeychainAccessGroup"

    static func store(
        _ token: String,
        for profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws -> Data {
        guard !token.isEmpty, let tokenData = token.data(using: .utf8) else {
            throw AuthTokenKeychainError.invalidToken
        }

        var addQuery = try identityQuery(for: profileID, service: service)
        addQuery[kSecValueData as String] = tokenData
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecReturnPersistentRef as String] = true

        let (addStatus, result) = client.add(addQuery)
        switch addStatus {
        case errSecSuccess:
            guard let reference = result as? Data else {
                throw AuthTokenKeychainError.missingPersistentReference
            }
            return reference
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: tokenData,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = client.update(
                try identityQuery(for: profileID, service: service), attributes)
            guard updateStatus == errSecSuccess else {
                throw AuthTokenKeychainError.security(
                    operation: "update auth token", status: updateStatus)
            }
            return try persistentReference(for: profileID, service: service, client: client)
        default:
            throw AuthTokenKeychainError.security(
                operation: "store auth token", status: addStatus)
        }
    }

    #if os(iOS)
    /// iOS-only: resolve the token through the `passwordReference` persistent
    /// ref stored on the `NETunnelProviderProtocol`. The ref already encodes
    /// the item's identity and access group. Adding kSecClass,
    /// kSecAttrAccessGroup, kSecMatchLimit, or kSecUseDataProtectionKeychain
    /// alongside kSecValuePersistentRef makes SecItemCopyMatching fail with
    /// errSecParam (-50, "one or more parameters passed to a function were
    /// not valid").
    static func token(
        for persistentReference: Data,
        client: AuthTokenKeychainClient = .security
    ) throws -> String {
        try decodeToken(client.copyMatching([
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnData as String: true,
        ]))
    }
    #endif

    /// Resolve the token by item identity (service + profile UUID + access
    /// group) in the data-protection keychain. This is the macOS app-side
    /// lookup only: it runs in the user context, where the data-protection
    /// keychain is available. The packet-tunnel system extension runs as a
    /// root daemon with no user context and cannot read the data-protection
    /// keychain; it must use daemonToken(for:) against the System keychain
    /// instead (see the daemon-side storage section below).
    static func token(
        forProfileID profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws -> String {
        var query = try identityQuery(for: profileID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try decodeToken(client.copyMatching(query))
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
    // the token to the provider in the tunnel-start options
    // (TunnelStartOption.authToken); the provider persists it here so
    // system-initiated restarts (reboot, crash recovery) can still connect.
    // No kSecUseDataProtectionKeychain and no kSecAttrAccessGroup: both are
    // data-protection-keychain concepts.

    static func persistDaemonToken(
        _ token: String,
        for profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws {
        guard !token.isEmpty, let tokenData = token.data(using: .utf8) else {
            throw AuthTokenKeychainError.invalidToken
        }
        var addQuery = daemonIdentityQuery(for: profileID, service: service)
        addQuery[kSecValueData as String] = tokenData

        let (status, _) = client.add(addQuery)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = client.update(
                daemonIdentityQuery(for: profileID, service: service),
                [kSecValueData as String: tokenData])
            guard updateStatus == errSecSuccess else {
                throw AuthTokenKeychainError.security(
                    operation: "update daemon auth token", status: updateStatus)
            }
        default:
            throw AuthTokenKeychainError.security(
                operation: "store daemon auth token", status: status)
        }
    }

    static func daemonToken(
        for profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws -> String {
        var query = daemonIdentityQuery(for: profileID, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try decodeToken(client.copyMatching(query))
    }

    /// macOS daemon-side delete against the System keychain (mirror of the
    /// data-protection `delete(for:service:)`). Used to clear the optional relay
    /// token when it is removed from a profile.
    static func deleteDaemonToken(
        for profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws {
        let status = client.delete(daemonIdentityQuery(for: profileID, service: service))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthTokenKeychainError.security(
                operation: "delete daemon auth token", status: status)
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

    private static func decodeToken(
        _ result: AuthTokenKeychainClient.Result
    ) throws -> String {
        guard result.status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token", status: result.status)
        }
        guard
            let data = result.value as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            throw AuthTokenKeychainError.invalidToken
        }
        return token
    }

    static func delete(
        for profileID: UUID,
        service: String = AuthTokenKeychain.service,
        client: AuthTokenKeychainClient = .security
    ) throws {
        let status = client.delete(try identityQuery(for: profileID, service: service))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthTokenKeychainError.security(
                operation: "delete auth token", status: status)
        }
    }

    private static func persistentReference(
        for profileID: UUID,
        service: String,
        client: AuthTokenKeychainClient
    ) throws -> Data {
        var query = try identityQuery(for: profileID, service: service)
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = client.copyMatching(query)
        guard status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token reference", status: status)
        }
        guard let reference = result as? Data else {
            throw AuthTokenKeychainError.missingPersistentReference
        }
        return reference
    }

    private static func identityQuery(
        for profileID: UUID, service: String
    ) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
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
            throw AuthTokenKeychainError.missingAccessGroup
        }
        return accessGroup
    }
}

enum AuthTokenKeychainError: LocalizedError {
    case missingAccessGroup
    case missingPersistentReference
    case invalidToken
    case security(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessGroup:
            return "The shared Keychain access group is not configured."
        case .missingPersistentReference:
            return "The Keychain did not return an auth-token reference."
        case .invalidToken:
            return "The Keychain auth token is empty or invalid."
        case .security(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            return "Could not \(operation): \(detail)."
        }
    }
}
