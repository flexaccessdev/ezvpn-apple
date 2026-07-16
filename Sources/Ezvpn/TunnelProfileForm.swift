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
    var routes = ""
    var routes6 = ""
    var dnsServers = ""
    var dnsMatchDomains = ""

    init() {}

    init(profile: TunnelProfile) {
        name = profile.name
        serverNodeID = profile.serverNodeID
        authToken = profile.authToken
        relayURLs = profile.relayURLs.joined(separator: ", ")
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

    /// Convert the editor fields into the persisted profile model.
    ///
    /// DNS fields are accepted only on iOS. macOS deliberately preserves the
    /// host's DNS configuration, so its caller passes `includesDNS: false`.
    func makeProfile(id: UUID, includesDNS: Bool) throws -> TunnelProfile {
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

        return TunnelProfile(
            id: id,
            name: Self.trimmed(name),
            serverNodeID: Self.trimmed(serverNodeID),
            authToken: Self.trimmed(authToken),
            relayURLs: Self.splitCSV(relayURLs),
            routes: Self.splitCSV(routes),
            routes6: Self.splitCSV(routes6),
            dnsServers: dnsServerList,
            dnsMatchDomains: dnsMatchDomainList
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

enum TunnelProfileFormError: LocalizedError, Equatable {
    case invalidDNS(String)

    var errorDescription: String? {
        switch self {
        case .invalidDNS(let message): message
        }
    }
}
