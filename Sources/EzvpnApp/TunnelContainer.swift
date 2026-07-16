import Foundation
import NetworkExtension
import TunnelCore

extension NEVPNStatus {
    /// The tunnel session is doing something — not fully down. Used to decide
    /// whether a new activation must first wait for this one to deactivate.
    var isInOperation: Bool {
        switch self {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        case .invalid, .disconnected: return false
        @unknown default: return false
        }
    }
}

/// One VPN profile, wrapping its `NETunnelProviderManager`. Mirrors the shape of
/// the WireGuard app's `TunnelContainer`, adapted to SwiftUI: an
/// `ObservableObject` whose `id` is the profile's stable UUID, so list rows
/// survive renames. `TunnelsManager` owns the array of these and drives their
/// lifecycle; a container never starts/stops itself except through the manager.
@MainActor
final class TunnelContainer: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var name: String
    /// Raw system connection status.
    @Published private(set) var status: NEVPNStatus
    @Published private(set) var connectedDate: Date?
    @Published private(set) var runtimeInfo: RuntimeInfo?
    @Published var lastError: String?

    /// Set while this tunnel is queued behind another that must deactivate
    /// first — the UI shows it as connecting even though its own session is
    /// still down. Cleared when its real activation begins.
    @Published var isWaiting = false
    /// Set when the tunnel must stop and immediately start again (config
    /// changed while running, or an add knocked it down). The manager's status
    /// observer restarts it once it reaches `.disconnected`.
    @Published var isRestarting = false

    /// The manager this container wraps. Owned/mutated by `TunnelsManager`;
    /// re-pointed on preference reloads via `attach`.
    var manager: NETunnelProviderManager

    /// Fired once when this tunnel next reaches `.disconnected` (used to start a
    /// tunnel that was waiting behind it). Consumed and cleared by the observer.
    var onDeactivated: (() -> Void)?

    /// True between `startActivation` and the resulting connected/disconnected.
    var isAttemptingActivation = false

    /// The decoded profile (connection params + name), or nil if the manager's
    /// providerConfiguration is malformed.
    var profile: TunnelProfile? {
        guard
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
            let conf = proto.providerConfiguration
        else { return nil }
        return TunnelProfile.from(providerConfiguration: conf, name: name)
    }

    /// Decoded reply to the runtime-configuration app message (see
    /// `PacketTunnelProvider.handleAppMessage`) — what was actually applied to
    /// the interface. nil while the tunnel is down.
    struct RuntimeInfo: Equatable {
        var assignedIP: String?
        var assignedIP6: String?
        var mtu: Int?
        var includedRoutes: [String]
        var includedRoutes6: [String]
        var bypassRoutes: [String]
        var bypassRoutes6: [String]
        var dnsServers: [String]
        var dnsMatchDomains: [String]
    }

    /// The profile's stable UUID, read from the manager's providerConfiguration.
    static func profileID(of manager: NETunnelProviderManager) -> UUID? {
        guard
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
            let conf = proto.providerConfiguration,
            let idString = conf[ProviderConfigKey.profileID] as? String
        else { return nil }
        return UUID(uuidString: idString)
    }

    /// Fails when the manager carries no stable `profile_id` (e.g. a config from
    /// a pre-multi-profile build); such managers have no usable identity.
    init?(manager: NETunnelProviderManager) {
        guard let id = TunnelContainer.profileID(of: manager) else { return nil }
        self.id = id
        self.manager = manager
        self.name = manager.localizedDescription ?? "Unnamed"
        self.status = manager.connection.status
        self.connectedDate = manager.connection.connectedDate
    }

    /// Re-point at a freshly reloaded manager object (same profile), keeping this
    /// container's identity and observers intact.
    func attach(_ manager: NETunnelProviderManager) {
        self.manager = manager
        self.name = manager.localizedDescription ?? name
    }

    func setName(_ name: String) { self.name = name }

    /// Pull `status`/`connectedDate` from the system connection and refresh
    /// runtime info while connected. Surfaces the tunnel's own failure reason
    /// when a session ends unexpectedly (but not during an intentional restart).
    func refreshStatus() {
        let conn = manager.connection
        let previous = status
        status = conn.status
        connectedDate = conn.connectedDate

        if status == .connected {
            Task { await refreshRuntimeInfo() }
        } else {
            runtimeInfo = nil
        }

        let wasActive = previous == .connecting || previous == .connected
            || previous == .reasserting || previous == .disconnecting
        if status == .disconnected, wasActive, !isRestarting, !isWaiting {
            fetchLastDisconnectError()
        }
    }

    /// Start this tunnel's session. Ensures the manager is enabled first, and
    /// retries once on a stale/invalid configuration by reloading — the
    /// difference between working on a clean device and after the user toggled
    /// the config in Settings > VPN.
    func startActivation(retriesRemaining: Int = 3) async {
        isWaiting = false
        lastError = nil

        if !manager.isEnabled {
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                isAttemptingActivation = false
                lastError = "enable failed: \(error.localizedDescription)"
                return
            }
        }

        do {
            isAttemptingActivation = true
            try (manager.connection as? NETunnelProviderSession)?.startTunnel(options: nil)
            refreshStatus()
        } catch let error as NEVPNError
            where (error.code == .configurationInvalid || error.code == .configurationStale)
                && retriesRemaining > 0 {
            try? await manager.loadFromPreferences()
            await startActivation(retriesRemaining: retriesRemaining - 1)
        } catch {
            isAttemptingActivation = false
            lastError = "connect failed: \(error.localizedDescription)"
        }
    }

    /// Stop this tunnel's session.
    func startDeactivation() {
        isAttemptingActivation = false
        (manager.connection as? NETunnelProviderSession)?.stopTunnel()
        refreshStatus()
    }

    /// Send a one-byte query to the running tunnel process and return its raw
    /// reply (the WireGuard app's provider-message protocol). nil when the
    /// tunnel is down or the message could not be delivered.
    private func sendTunnelQuery(_ byte: UInt8) async -> Data? {
        guard
            status == .connected,
            let session = manager.connection as? NETunnelProviderSession
        else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data([byte])) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Ask the running tunnel for its applied network config (byte 0).
    func refreshRuntimeInfo() async {
        guard
            let reply = await sendTunnelQuery(0),
            let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else {
            runtimeInfo = nil
            return
        }
        runtimeInfo = RuntimeInfo(
            assignedIP: obj["assigned_ip"] as? String,
            assignedIP6: obj["assigned_ip6"] as? String,
            mtu: obj["mtu"] as? Int,
            includedRoutes: obj["included_routes"] as? [String] ?? [],
            includedRoutes6: obj["included_routes6"] as? [String] ?? [],
            bypassRoutes: obj["bypass_routes"] as? [String] ?? [],
            bypassRoutes6: obj["bypass_routes6"] as? [String] ?? [],
            dnsServers: obj["dns_servers"] as? [String] ?? [],
            dnsMatchDomains: obj["dns_match_domains"] as? [String] ?? []
        )
    }

    /// One live iroh connection path, decoded from the tunnel's
    /// `ezvpn_conn_path` snapshot (see `ConnPathSheet`).
    struct ConnPath: Identifiable {
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

    /// Snapshot how the running tunnel currently reaches the server (byte 1):
    /// all discovered iroh paths, empty while none are established.
    func queryConnPaths() async -> [ConnPath] {
        guard
            let reply = await sendTunnelQuery(1),
            let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
            let raw = obj["paths"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let display = entry["display"] as? String else { return nil }
            return ConnPath(
                kind: (entry["kind"] as? String).flatMap(ConnPath.Kind.init) ?? .other,
                display: display,
                selected: entry["selected"] as? Bool ?? false
            )
        }
    }

    private func fetchLastDisconnectError() {
        guard let session = manager.connection as? NETunnelProviderSession else { return }
        session.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            // The system wraps the provider's own error in a generic
            // NEVPNConnectionError; prefer the underlying provider message.
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let message = underlying?.localizedDescription ?? error.localizedDescription
            Task { @MainActor in self?.lastError = message }
        }
    }
}
