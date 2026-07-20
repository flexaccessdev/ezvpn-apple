import Foundation
import TunnelCore

/// Editable text representation of a tunnel profile.
///
/// SwiftUI owns this value while the profile editor is on screen. Keeping the
/// parsing and validation here makes the form-to-model boundary deterministic
/// and testable without presenting a view or touching NetworkExtension.
struct TunnelProfileForm: Equatable {
    var name = ""
    var serverNodeID = ""
    var authToken = ""
    var relayURLs = ""
    var relayAuthToken = ""
    var routes = ""
    var routes6 = ""
    var dnsServers = ""
    var dnsMatchDomains = ""

    init() {}

    init(profile: TunnelProfile, authToken: String, relayAuthToken: String = "") {
        name = profile.name
        serverNodeID = profile.serverNodeID
        self.authToken = authToken
        relayURLs = profile.relayURLs.joined(separator: ", ")
        self.relayAuthToken = relayAuthToken
        routes = profile.routes.joined(separator: ", ")
        routes6 = profile.routes6.joined(separator: ", ")
        dnsServers = profile.dnsServers.joined(separator: ", ")
        dnsMatchDomains = profile.dnsMatchDomains.joined(separator: ", ")
    }

    var hasRequiredFields: Bool {
        !Self.trimmed(name).isEmpty
            && !Self.trimmed(serverNodeID).isEmpty
            && !Self.trimmed(authToken).isEmpty
    }

    /// Validate the editor fields and separate the non-secret profile from the
    /// token that will be written directly to the Keychain.
    ///
    /// DNS fields are accepted only on iOS. macOS deliberately preserves the
    /// host's DNS configuration, so its caller passes `includesDNS: false`.
    func makeSubmission(id: UUID, includesDNS: Bool) throws -> TunnelProfileSubmission {
        guard hasRequiredFields else {
            throw TunnelProfileFormError.missingRequiredFields
        }

        let dnsServerList = includesDNS ? Self.splitCSV(dnsServers) : []
        let dnsMatchDomainList = includesDNS
            ? Self.splitCSV(dnsMatchDomains).map(normalizedDNSMatchDomain)
            : []

        if let message = splitDNSValidationError(
            servers: dnsServerList,
            matchDomains: dnsMatchDomainList
        ) {
            throw TunnelProfileFormError.invalidDNS(message)
        }

        let relayURLList = Self.splitCSV(relayURLs)
        let relayToken = Self.trimmed(relayAuthToken)
        // The relay token is only valid with custom relays; reject it up front
        // rather than letting the core fail the connection later.
        if !relayToken.isEmpty, relayURLList.isEmpty {
            throw TunnelProfileFormError.relayTokenWithoutRelays
        }

        return TunnelProfileSubmission(
            profile: TunnelProfile(
                id: id,
                name: Self.trimmed(name),
                serverNodeID: Self.trimmed(serverNodeID),
                relayURLs: relayURLList,
                routes: Self.splitCSV(routes),
                routes6: Self.splitCSV(routes6),
                dnsServers: dnsServerList,
                dnsMatchDomains: dnsMatchDomainList
            ),
            authToken: Self.trimmed(authToken),
            // Kept out of the profile: the relay token is a secret and is
            // persisted in the Keychain, like `authToken`. nil == no token.
            relayAuthToken: relayToken.isEmpty ? nil : relayToken
        )
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitCSV(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The editor's validated output keeps the secret separate from the profile
/// model that is serialized into Network Extension preferences.
struct TunnelProfileSubmission: Equatable {
    let profile: TunnelProfile
    let authToken: String
    /// Optional shared relay bearer token, kept separate from the profile
    /// because it is a secret (Keychain-stored). nil means no token.
    let relayAuthToken: String?
}

enum TunnelProfileFormError: LocalizedError, Equatable {
    case missingRequiredFields
    case invalidDNS(String)
    case relayTokenWithoutRelays

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields: "Name, server node id, and auth token are required."
        case .invalidDNS(let message): message
        case .relayTokenWithoutRelays: "A relay token requires at least one relay URL."
        }
    }
}
