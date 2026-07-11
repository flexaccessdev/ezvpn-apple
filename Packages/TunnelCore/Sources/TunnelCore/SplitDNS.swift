import Darwin
import Foundation

/// True when `s` is a literal IPv4 or IPv6 address (no hostnames — the tunnel's
/// DNS servers must be reachable without resolution).
public func isIPAddressLiteral(_ s: String) -> Bool {
    var v4 = in_addr()
    if inet_pton(AF_INET, s, &v4) == 1 { return true }
    var v6 = in6_addr()
    return inet_pton(AF_INET6, s, &v6) == 1
}

/// Canonical form of a user-typed match domain: trimmed, lowercased, with the
/// leading dot of the ".zone" convention (Windows NRPT, /etc/resolver) and any
/// trailing root dot stripped — `NEDNSSettings.matchDomains` wants the bare
/// suffix ("local.example.com").
public func normalizedDNSMatchDomain(_ raw: String) -> String {
    var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if domain.hasPrefix(".") { domain.removeFirst() }
    if domain.hasSuffix(".") { domain.removeLast() }
    return domain
}

/// Why a profile's split-DNS fields are unusable, as a message for the editor;
/// nil when acceptable. Servers must be IP literals; match domains without any
/// server would silently resolve nothing, so that combination is rejected
/// rather than saved.
public func splitDNSValidationError(servers: [String], matchDomains: [String]) -> String? {
    if servers.isEmpty {
        return matchDomains.isEmpty ? nil : "Match domains require at least one DNS server."
    }
    if let bad = servers.first(where: { !isIPAddressLiteral($0) }) {
        return "DNS server is not an IP address: \(bad)"
    }
    if let bad = matchDomains.first(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) || $0.contains("/") }) {
        return "Match domain is not a domain suffix: \(bad)"
    }
    return nil
}

/// The DNS servers not covered by any same-family route — queries to them
/// will not ride the tunnel, which for a private resolver means they silently
/// go to the underlying network and fail. Unparseable servers are reported
/// too: they are certainly not reachable. Callers pass the route set actually
/// applied to the interface (user routes plus interface/gateway routes).
public func dnsServersOutsideRoutes(
    servers: [String], routes: [String], routes6: [String]
) -> [String] {
    let nets4 = routes.compactMap { parseCIDR($0, family: AF_INET) }
    let nets6 = routes6.compactMap { parseCIDR($0, family: AF_INET6) }
    return servers.filter { server in
        if let (bytes, _) = parseCIDR("\(server)/32", family: AF_INET) {
            return !nets4.contains { prefixesOverlap(bytes, 32, $0.bytes, $0.prefix) }
        }
        if let (bytes, _) = parseCIDR("\(server)/128", family: AF_INET6) {
            return !nets6.contains { prefixesOverlap(bytes, 128, $0.bytes, $0.prefix) }
        }
        return true
    }
}
