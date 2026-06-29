import Foundation
import NetworkExtension
import Combine

/// Drives the on-device VPN configuration and the tunnel session via
/// NetworkExtension. The actual networking happens in the PacketTunnel
/// extension; this class only installs the configuration and starts/stops it.
@MainActor
final class VPNController: ObservableObject {
    /// Bundle id of the Packet Tunnel extension (must match project.yml).
    private let providerBundleID = "com.example.ezvpn.PacketTunnel"

    @Published var status: String = "idle"
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        Task { await reload() }
    }

    /// Connection parameters entered in the UI.
    struct Settings {
        var serverNodeID: String
        var alpnToken: String
        var authToken: String
        var relayURLs: [String]
        /// IPv4 private CIDRs to route through the tunnel (split tunnel).
        var routes: [String]
        /// IPv6 CIDRs to route through the tunnel (split tunnel).
        var routes6: [String]
    }

    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            observeStatus()
            updateStatus()
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
                "alpn_token": s.alpnToken,
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
            observeStatus()

            try mgr.connection.startVPNTunnel()
            updateStatus()
        } catch {
            lastError = "connect failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
        updateStatus()
    }

    private func observeStatus() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        guard let conn = manager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: conn, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
    }

    private func updateStatus() {
        guard let conn = manager?.connection else { status = "not installed"; return }
        switch conn.status {
        case .invalid: status = "invalid"
        case .disconnected: status = "disconnected"
        case .connecting: status = "connecting"
        case .connected: status = "connected"
        case .reasserting: status = "reasserting"
        case .disconnecting: status = "disconnecting"
        @unknown default: status = "unknown"
        }
    }
}
