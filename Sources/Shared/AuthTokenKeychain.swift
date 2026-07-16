import Foundation
import Security

/// Shared Keychain storage for profile authentication tokens.
///
/// The containing app creates and updates the item; the packet-tunnel
/// extension resolves the persistent reference stored in
/// `NETunnelProviderProtocol.passwordReference`. Both targets carry the same
/// keychain-access-group entitlement.
enum AuthTokenKeychain {
    static let service = "ezvpn.auth-token"
    static let accessGroupInfoKey = "EZVPNKeychainAccessGroup"

    static func store(_ token: String, for profileID: UUID) throws -> Data {
        guard !token.isEmpty, let tokenData = token.data(using: .utf8) else {
            throw AuthTokenKeychainError.invalidToken
        }

        var addQuery = try identityQuery(for: profileID)
        addQuery[kSecValueData as String] = tokenData
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecReturnPersistentRef as String] = true

        var result: CFTypeRef?
        let addStatus = SecItemAdd(addQuery as CFDictionary, &result)
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
            let updateStatus = SecItemUpdate(
                try identityQuery(for: profileID) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw AuthTokenKeychainError.security(
                    operation: "update auth token", status: updateStatus)
            }
            return try persistentReference(for: profileID)
        default:
            throw AuthTokenKeychainError.security(
                operation: "store auth token", status: addStatus)
        }
    }

    static func token(for persistentReference: Data) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: try accessGroup(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        #if os(macOS)
        // macOS resolves persistent references through kSecMatchItemList;
        // kSecValuePersistentRef is the iOS-family query form.
        query[kSecMatchItemList as String] = [persistentReference]
        #else
        query[kSecValuePersistentRef as String] = persistentReference
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token", status: status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            throw AuthTokenKeychainError.invalidToken
        }
        return token
    }

    static func delete(for profileID: UUID) throws {
        let status = SecItemDelete(try identityQuery(for: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthTokenKeychainError.security(
                operation: "delete auth token", status: status)
        }
    }

    private static func persistentReference(for profileID: UUID) throws -> Data {
        var query = try identityQuery(for: profileID)
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw AuthTokenKeychainError.security(
                operation: "load auth token reference", status: status)
        }
        guard let reference = result as? Data else {
            throw AuthTokenKeychainError.missingPersistentReference
        }
        return reference
    }

    private static func identityQuery(for profileID: UUID) throws -> [String: Any] {
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
