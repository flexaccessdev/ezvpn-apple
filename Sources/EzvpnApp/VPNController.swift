import Foundation
import NetworkExtension
import Combine

/// Drives the on-device VPN configuration and the tunnel session via
/// NetworkExtension. The actual networking happens in the PacketTunnel
/// extension; this class only installs the configuration and starts/stops it.
///
/// The OS is the source of truth for connection state: `status` mirrors
/// `NEVPNConnection.status`, so the UI stays in sync no matter where the
/// tunnel was started or stopped from (this app, Settings > VPN, or the OS
/// tearing it down) — the same model the WireGuard app uses.
@MainActor
final class VPNController: ObservableObject {
    /// Bundle id of the Packet Tunnel extension (must match project.yml).
    private let providerBundleID = "com.example.ezvpn.PacketTunnel"

    /// Mirrors the system's connection status. `.invalid` until a configuration
    /// exists (or after it is deleted in Settings).
    @Published private(set) var status: NEVPNStatus = .invalid
    /// When the current session connected, for a "connected since" display.
    @Published private(set) var connectedDate: Date?
    /// The configuration last saved to VPN preferences, used to prefill the
    /// form on launch so the UI reflects what the system will actually run.
    @Published private(set) var savedSettings: Settings?
    /// Live state reported by the running tunnel process (assigned addresses,
    /// tunnel routes, bypass routes) — what was actually applied to the
    /// interface, not what was requested. nil while the tunnel is down.
    @Published private(set) var runtimeInfo: RuntimeInfo?
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []

    /// Connection parameters entered in the UI.
    struct Settings: Equatable {
        var serverNodeID: String
        var authToken: String
        var relayURLs: [String]
        /// IPv4 private CIDRs to route through the tunnel (split tunnel).
        var routes: [String]
        /// IPv6 CIDRs to route through the tunnel (split tunnel).
        var routes6: [String]
    }

    /// Decoded reply to the runtime-configuration app message (see
    /// `PacketTunnelProvider.handleAppMessage`).
    struct RuntimeInfo: Equatable {
        var assignedIP: String?
        var assignedIP6: String?
        var mtu: Int?
        /// CIDRs routed through the tunnel, per family.
        var includedRoutes: [String]
        var includedRoutes6: [String]
        /// Server underlay/relay CIDRs carved back out of the tunnel
        /// (`excludedRoutes`) so the transport never self-captures.
        var bypassRoutes: [String]
        var bypassRoutes6: [String]
    }

    init() {
        // Observe globally (object: nil) rather than per-connection: every
        // preferences reload materializes a new connection object, which would
        // silently orphan a per-object observer. Global + re-read keeps the UI
        // honest even for status changes triggered from Settings > VPN.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncStatus() }
        })
        // Configuration edited/removed outside the app (e.g. deleted in
        // Settings): reload so `manager` doesn't go stale.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
        Task { await reload() }
    }

    /// Re-read VPN preferences and re-sync status. Called on init, on
    /// configuration changes, and when the app returns to the foreground
    /// (notifications can be missed while suspended).
    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            savedSettings = manager.flatMap(Self.settings(from:))
            syncStatus()
        } catch {
            lastError = "load failed: \(error.localizedDescription)"
        }
    }

    /// Save the configuration and start the tunnel.
    func connect(_ s: Settings) async {
        lastError = nil
        do {
            let mgr = manager ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleID
            // serverAddress is shown in Settings > VPN; node id is fine here.
            proto.serverAddress = s.serverNodeID
            // Everything the extension needs is plist-serializable here.
            proto.providerConfiguration = [
                "server_node_id": s.serverNodeID,
                "auth_token": s.authToken,
                "relay_urls": s.relayURLs,
                "routes": s.routes,
                "routes6": s.routes6,
            ]

            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "ezvpn POC"
            mgr.isEnabled = true

            try await mgr.saveToPreferences()
            // Re-load so the saved config is fully materialized before starting.
            try await mgr.loadFromPreferences()
            manager = mgr
            savedSettings = s

            try mgr.connection.startVPNTunnel()
            syncStatus()
        } catch {
            lastError = "connect failed: \(error.localizedDescription)"
        }
    }

    /// Stop the tunnel.
    func disconnect() async {
        guard let mgr = manager else { return }
        mgr.connection.stopVPNTunnel()
        syncStatus()
    }

    /// Pull `status` from the system connection. Also surfaces the tunnel's own
    /// failure reason when a session ends without the user asking it to.
    private func syncStatus() {
        guard let conn = manager?.connection else {
            status = .invalid
            connectedDate = nil
            return
        }
        let previous = status
        status = conn.status
        connectedDate = conn.connectedDate

        // Runtime info only exists while the tunnel process runs. Refresh on
        // every sync while connected (foreground returns land here too, where
        // the tunnel may have reconnected with different bypass routes).
        if status == .connected {
            Task { await refreshRuntimeInfo() }
        } else {
            runtimeInfo = nil
        }

        // A session that lands back at .disconnected may have failed on the
        // tunnel side; ask the system why. Failed starts pass through
        // .disconnecting on the way down (.connecting → .disconnecting →
        // .disconnected), so it counts as active here — the fetch returns nil
        // for a clean user-initiated stop, which stays silent.
        let wasActive = previous == .connecting || previous == .connected
            || previous == .reasserting || previous == .disconnecting
        if status == .disconnected, wasActive {
            conn.fetchLastDisconnectError { [weak self] error in
                guard let error else { return }
                // The system wraps the provider's own error (the message passed
                // to startTunnel's completion) in a generic NEVPNConnectionError;
                // prefer the underlying provider message when present.
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                let message = underlying?.localizedDescription ?? error.localizedDescription
                Task { @MainActor in
                    self?.lastError = message
                }
            }
        }
    }

    /// Ask the running tunnel for its applied network config, using the
    /// WireGuard app's protocol: send the single byte 0, get JSON back.
    func refreshRuntimeInfo() async {
        guard
            status == .connected,
            let session = manager?.connection as? NETunnelProviderSession
        else {
            runtimeInfo = nil
            return
        }
        let reply: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard
            let reply,
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
            bypassRoutes6: obj["bypass_routes6"] as? [String] ?? []
        )
    }

    private static func settings(from manager: NETunnelProviderManager) -> Settings? {
        guard
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
            let conf = proto.providerConfiguration
        else { return nil }
        return Settings(
            serverNodeID: conf["server_node_id"] as? String ?? "",
            authToken: conf["auth_token"] as? String ?? "",
            relayURLs: conf["relay_urls"] as? [String] ?? [],
            routes: conf["routes"] as? [String] ?? [],
            routes6: conf["routes6"] as? [String] ?? []
        )
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
