import Foundation

/// One saved VPN profile: the connection parameters plus a stable identity and
/// a display name. The app persists each profile as its own
/// `NETunnelProviderManager` (name in `localizedDescription`, everything else in
/// `providerConfiguration`), so this type is the pure, testable payload that
/// crosses that boundary — no NetworkExtension dependency, only Foundation.
///
/// `id` is a UUID minted once when the profile is created and carried in
/// `providerConfiguration` (see `ProviderConfigKey.profileID`). It is the
/// SwiftUI identity, stable across renames and preferences reloads — unlike the
/// name, which changes. The WireGuard app keys tunnels by name; a persisted UUID
/// avoids the row churn that causes on rename.
public struct TunnelProfile: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Display name; also the manager's `localizedDescription`. Unique per app.
    public var name: String
    public var serverNodeID: String
    /// Which key from the app's shared auth-key list this profile
    /// authenticates with (`AuthKeyStore.Key.id`). The key's *secret* is never
    /// here — it is copied into the profile's own Keychain item on save (see
    /// `AuthKeyKeychain`); this is only the non-secret reference the editor
    /// re-selects and the UI names the key by.
    public var authKeyID: String
    public var relayURLs: [String]
    /// IPv4 private CIDRs to route through the tunnel (split tunnel).
    public var routes: [String]
    /// IPv6 CIDRs to route through the tunnel (split tunnel).
    public var routes6: [String]
    /// DNS server IPs the tunnel provides. Empty = the tunnel touches no DNS.
    public var dnsServers: [String]
    /// Domain suffixes resolved via `dnsServers` (split DNS / conditional
    /// forwarding); every other name keeps the physical network's resolvers.
    /// Empty with `dnsServers` set = all DNS goes through the tunnel.
    public var dnsMatchDomains: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        serverNodeID: String,
        authKeyID: String,
        relayURLs: [String],
        routes: [String],
        routes6: [String],
        dnsServers: [String],
        dnsMatchDomains: [String]
    ) {
        self.id = id
        self.name = name
        self.serverNodeID = serverNodeID
        self.authKeyID = authKeyID
        self.relayURLs = relayURLs
        self.routes = routes
        self.routes6 = routes6
        self.dnsServers = dnsServers
        self.dnsMatchDomains = dnsMatchDomains
    }
}

/// Keys used in the `NETunnelProviderProtocol.providerConfiguration` plist
/// dictionary. `serverNodeID`/`relayURLs`/`routes`/`routes6`/
/// `dnsServers`/`dnsMatchDomains` are the keys the PacketTunnel extension
/// reads — do not rename them without updating
/// `PacketTunnelProvider.startTunnel`. `profileID`/`name`/`authKeyID` are
/// additive and ignored by the extension.
///
/// No secret is here: the client's ed25519 auth key and the optional relay
/// bearer token live in the Keychain (see `AuthKeyKeychain`), keyed by profile
/// id under `AuthKeyKeychain.service` and `AuthKeyKeychain.relayService`.
/// `authKeyID` names which entry of the app's shared key list the secret came
/// from, which is not itself sensitive.
public enum ProviderConfigKey {
    public static let profileID = "profile_id"
    public static let name = "name"
    public static let serverNodeID = "server_node_id"
    public static let authKeyID = "auth_key_id"
    public static let relayURLs = "relay_urls"
    public static let routes = "routes"
    public static let routes6 = "routes6"
    public static let dnsServers = "dns_servers"
    public static let dnsMatchDomains = "dns_match_domains"
}

public extension TunnelProfile {
    /// The plist-serializable dictionary stored as the manager's
    /// `providerConfiguration`. Foundation-only (`[String: Any]`); the app wraps
    /// it in an `NETunnelProviderProtocol`.
    func providerConfiguration() -> [String: Any] {
        [
            ProviderConfigKey.profileID: id.uuidString,
            ProviderConfigKey.name: name,
            ProviderConfigKey.serverNodeID: serverNodeID,
            ProviderConfigKey.authKeyID: authKeyID,
            ProviderConfigKey.relayURLs: relayURLs,
            ProviderConfigKey.routes: routes,
            ProviderConfigKey.routes6: routes6,
            ProviderConfigKey.dnsServers: dnsServers,
            ProviderConfigKey.dnsMatchDomains: dnsMatchDomains,
        ]
    }

    /// Rebuild a profile from a manager's `providerConfiguration` plus its
    /// `localizedDescription` (the name source of truth). Returns nil when the
    /// stable `profile_id` is missing or unparseable — such a manager has no
    /// usable identity and is skipped by the caller.
    static func from(providerConfiguration conf: [String: Any], name: String) -> TunnelProfile? {
        guard
            let idString = conf[ProviderConfigKey.profileID] as? String,
            let id = UUID(uuidString: idString)
        else { return nil }
        return TunnelProfile(
            id: id,
            name: name,
            serverNodeID: conf[ProviderConfigKey.serverNodeID] as? String ?? "",
            authKeyID: conf[ProviderConfigKey.authKeyID] as? String ?? "",
            relayURLs: conf[ProviderConfigKey.relayURLs] as? [String] ?? [],
            routes: conf[ProviderConfigKey.routes] as? [String] ?? [],
            routes6: conf[ProviderConfigKey.routes6] as? [String] ?? [],
            dnsServers: conf[ProviderConfigKey.dnsServers] as? [String] ?? [],
            dnsMatchDomains: conf[ProviderConfigKey.dnsMatchDomains] as? [String] ?? []
        )
    }
}
