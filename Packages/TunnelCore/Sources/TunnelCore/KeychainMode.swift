import Foundation

/// Which Keychain the macOS app keeps its secrets in, chosen once at launch
/// from the `EZVPN_KEYCHAIN` environment variable (`keychainModeVariable`).
///
/// Unset, it is the real Keychain. `mock` keeps every secret in memory instead,
/// for an end-to-end test or a QA run that must neither prompt nor touch the
/// account's Keychain items and saved profiles: the secrets are gone when the
/// app quits, and so are the profiles saved under it (see `TunnelsManager`).
public enum KeychainMode: Equatable {
    case system
    case mock

    /// Parse the variable's value. It takes `mock` or nothing: any other value
    /// is refused rather than read as the real Keychain, so a typo never lands
    /// a test run on the account's secrets.
    public static func parse(_ value: String?) -> Result<KeychainMode, KeychainModeError> {
        switch value {
        case nil: return .success(.system)
        case "mock": return .success(.mock)
        case let value?: return .failure(KeychainModeError(value: value))
        }
    }
}

/// The environment variable `KeychainMode.parse` reads.
public let keychainModeVariable = "EZVPN_KEYCHAIN"

/// A refused `EZVPN_KEYCHAIN` value.
public struct KeychainModeError: Error, Equatable, CustomStringConvertible {
    public let value: String

    public var description: String {
        "\(keychainModeVariable) is \"\(value)\"; the only value it takes is \"mock\"."
    }
}
