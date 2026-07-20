import Foundation

/// Applied network configuration reported by the running packet tunnel.
struct TunnelRuntimeInfo: Equatable {
    let assignedIP: String?
    let assignedIP6: String?
    let mtu: Int?
    let includedRoutes: [String]
    let includedRoutes6: [String]
    let bypassRoutes: [String]
    let bypassRoutes6: [String]
    let dnsServers: [String]
    let dnsMatchDomains: [String]
}

/// One live iroh path from the app extension to the server.
struct TunnelConnectionPath: Identifiable {
    enum Kind: String {
        case direct, relay, other
    }

    let id = UUID()
    let kind: Kind
    /// Human line like "Direct 1.2.3.4:52186 (rtt 1ms)".
    let display: String
    /// Whether iroh currently routes traffic over this path.
    let selected: Bool
}

struct TunnelCustomRelay: Identifiable {
    let url: String
    let working: Bool?
    let error: String?

    var id: String { url }
}

struct TunnelConnectionSnapshot {
    let paths: [TunnelConnectionPath]
    let customRelays: [TunnelCustomRelay]
}

/// Pure decoder for the app-message replies sent by PacketTunnelProvider.
/// Keeping JSON interpretation out of `TunnelContainer` lets malformed and
/// partial provider replies be tested without a live VPN session.
enum TunnelSnapshotDecoder {
    static func runtimeInfo(from data: Data) -> TunnelRuntimeInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return TunnelRuntimeInfo(
            assignedIP: object["assigned_ip"] as? String,
            assignedIP6: object["assigned_ip6"] as? String,
            mtu: object["mtu"] as? Int,
            includedRoutes: object["included_routes"] as? [String] ?? [],
            includedRoutes6: object["included_routes6"] as? [String] ?? [],
            bypassRoutes: object["bypass_routes"] as? [String] ?? [],
            bypassRoutes6: object["bypass_routes6"] as? [String] ?? [],
            dnsServers: object["dns_servers"] as? [String] ?? [],
            dnsMatchDomains: object["dns_match_domains"] as? [String] ?? []
        )
    }

    static func connectionSnapshot(from data: Data) -> TunnelConnectionSnapshot {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return TunnelConnectionSnapshot(paths: [], customRelays: []) }

        let paths: [TunnelConnectionPath] =
            (object["paths"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let display = entry["display"] as? String else { return nil }
            return TunnelConnectionPath(
                kind: (entry["kind"] as? String).flatMap(TunnelConnectionPath.Kind.init) ?? .other,
                display: display,
                selected: entry["selected"] as? Bool ?? false
            )
        }
        let relays: [TunnelCustomRelay] =
            (object["custom_relays"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let url = entry["url"] as? String else { return nil }
            return TunnelCustomRelay(
                url: url,
                working: entry["working"] as? Bool,
                error: entry["error"] as? String
            )
        }
        return TunnelConnectionSnapshot(paths: paths, customRelays: relays)
    }
}
