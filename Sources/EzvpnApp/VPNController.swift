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
    /// Whether the saved configuration has Connect On Demand armed. True even
    /// while the tunnel itself is down (e.g. on Wi-Fi, where the rules keep it
    /// disconnected) — the UI shows this as a distinct "waiting" state, like
    /// the WireGuard app does.
    @Published private(set) var isOnDemandEnabled = false
    /// The configuration last saved to VPN preferences, used to prefill the
    /// form on launch so the UI reflects what the system will actually run.
    @Published private(set) var savedSettings: Settings?
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

            // On-demand, cellular only (v1, hardcoded — same shape as the
            // WireGuard app's "cellular only" option): the OS brings the
            // tunnel up whenever cellular is the active interface and keeps
            // it down on everything else. Rules are evaluated in order,
            // first match wins.
            let connectOnCellular = NEOnDemandRuleConnect()
            connectOnCellular.interfaceTypeMatch = .cellular
            let disconnectOtherwise = NEOnDemandRuleDisconnect()
            disconnectOtherwise.interfaceTypeMatch = .any
            mgr.onDemandRules = [connectOnCellular, disconnectOtherwise]
            mgr.isOnDemandEnabled = true

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

    /// Stop the tunnel. On-demand is switched off first — otherwise the OS
    /// would restart the tunnel immediately while still on cellular. It is
    /// re-enabled on the next `connect(_:)`.
    func disconnect() async {
        guard let mgr = manager else { return }
        if mgr.isOnDemandEnabled {
            do {
                mgr.isOnDemandEnabled = false
                try await mgr.saveToPreferences()
            } catch {
                lastError = "disconnect failed: \(error.localizedDescription)"
                return
            }
        }
        mgr.connection.stopVPNTunnel()
        syncStatus()
    }

    /// Pull `status` from the system connection. Also surfaces the tunnel's own
    /// failure reason when a session ends without the user asking it to.
    private func syncStatus() {
        isOnDemandEnabled = manager?.isOnDemandEnabled ?? false
        guard let conn = manager?.connection else {
            status = .invalid
            connectedDate = nil
            return
        }
        let previous = status
        status = conn.status
        connectedDate = conn.connectedDate

        // A connect attempt (or live session) that lands back at .disconnected
        // failed on the tunnel side; ask the system why.
        let wasActive = previous == .connecting || previous == .connected || previous == .reasserting
        if status == .disconnected, wasActive {
            conn.fetchLastDisconnectError { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                }
            }
        }
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
