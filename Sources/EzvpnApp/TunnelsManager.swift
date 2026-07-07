import Foundation
import NetworkExtension
import TunnelCore

/// Errors surfaced to the UI when managing profiles.
enum TunnelsManagerError: LocalizedError {
    case nameEmpty
    case nameDuplicate
    case system(Error)

    var errorDescription: String? {
        switch self {
        case .nameEmpty: return "Name can't be empty."
        case .nameDuplicate: return "A profile with that name already exists."
        case .system(let error): return error.localizedDescription
        }
    }
}

/// Owns the set of saved VPN profiles, each backed by its own
/// `NETunnelProviderManager` (all pointing at the same PacketTunnel extension).
/// SwiftUI-flavored counterpart of the WireGuard app's `TunnelsManager`: it
/// publishes an array of `TunnelContainer`, does the CRUD, serializes activation
/// (iOS runs at most one tunnel at a time), and routes system status
/// notifications to the right container.
@MainActor
final class TunnelsManager: ObservableObject {
    @Published private(set) var tunnels: [TunnelContainer] = []
    @Published var lastError: String?

    /// Bundle id of the Packet Tunnel extension (must match project.yml).
    private let providerBundleID = "com.example.ezvpn.PacketTunnel"

    private var statusObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    init() {
        // Observe globally (object: nil): every preferences reload materializes
        // new connection objects, so a per-object observer would go stale.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let object = note.object
            Task { @MainActor in self?.handleStatusNotification(object) }
        }
        // Config edited/removed outside the app (e.g. deleted in Settings).
        configObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // MARK: - Loading

    /// Re-read all VPN preferences, re-attaching reloaded managers to existing
    /// containers (so identity, observers, and in-flight activation state
    /// survive) and dropping any removed outside the app. Managers with no
    /// stable `profile_id` (e.g. from a pre-multi-profile build) are ignored.
    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            var next: [TunnelContainer] = []
            for manager in managers {
                guard let id = TunnelContainer.profileID(of: manager) else { continue }
                if let existing = tunnels.first(where: { $0.id == id }) {
                    existing.attach(manager)
                    existing.refreshStatus()
                    next.append(existing)
                } else if let container = TunnelContainer(manager: manager) {
                    next.append(container)
                }
            }
            tunnels = next.sorted { tunnelNameIsLessThan($0.name, $1.name) }
        } catch {
            lastError = "load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - CRUD

    /// Save a new profile and return its container. Applies the iOS quirk that
    /// saving a fresh manager deactivates any currently active tunnel — the
    /// previously active one is restarted so adding a profile doesn't silently
    /// drop the user's connection.
    @discardableResult
    func add(_ profile: TunnelProfile) async throws -> TunnelContainer {
        let name = try validatedName(profile.name, excluding: nil)
        var profile = profile
        profile.name = name

        let activeTunnel = tunnels.first { $0.status.isInOperation }

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = makeProtocol(for: profile)
        manager.localizedDescription = name
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw TunnelsManagerError.system(error)
        }

        // A concurrent reload (triggered by our own save) may have already
        // inserted this profile — don't duplicate it.
        let container = tunnels.first(where: { $0.id == profile.id })
            ?? TunnelContainer(manager: manager)!
        if !tunnels.contains(where: { $0.id == container.id }) {
            tunnels.append(container)
            tunnels.sort { tunnelNameIsLessThan($0.name, $1.name) }
        }

        restoreAfterAddDeactivation(activeTunnel)
        return container
    }

    /// Rewrite an existing profile's configuration and/or name. If it is running
    /// and the config changed, restart it so the change takes effect.
    func modify(_ tunnel: TunnelContainer, to profile: TunnelProfile) async throws {
        let name = try validatedName(profile.name, excluding: tunnel)
        var profile = profile
        profile.name = name

        tunnel.manager.protocolConfiguration = makeProtocol(for: profile)
        tunnel.manager.localizedDescription = name
        tunnel.manager.isEnabled = true
        do {
            try await tunnel.manager.saveToPreferences()
            try await tunnel.manager.loadFromPreferences()
        } catch {
            throw TunnelsManagerError.system(error)
        }
        tunnel.setName(name)
        tunnels.sort { tunnelNameIsLessThan($0.name, $1.name) }

        if tunnel.status.isInOperation {
            tunnel.isRestarting = true
            tunnel.startDeactivation()
        }
    }

    /// Delete a profile and its saved VPN configuration.
    func remove(_ tunnel: TunnelContainer) async throws {
        do {
            try await tunnel.manager.removeFromPreferences()
        } catch {
            throw TunnelsManagerError.system(error)
        }
        tunnels.removeAll { $0.id == tunnel.id }
    }

    // MARK: - Activation

    /// Start `tunnel`, first tearing down any other active tunnel and waiting
    /// for it to fully stop (iOS permits only one active tunnel at a time).
    func startActivation(of tunnel: TunnelContainer) async {
        guard tunnels.contains(where: { $0.id == tunnel.id }) else { return }
        guard !tunnel.status.isInOperation, !tunnel.isWaiting else { return }

        if let active = tunnels.first(where: { $0.id != tunnel.id && $0.status.isInOperation }) {
            tunnel.isWaiting = true
            active.onDeactivated = { [weak tunnel] in
                // Skip if the waiter was cancelled before the active tunnel
                // finished deactivating (startDeactivation clears isWaiting).
                guard let tunnel, tunnel.isWaiting else { return }
                Task { @MainActor in await tunnel.startActivation() }
            }
            active.startDeactivation()
            return
        }
        await tunnel.startActivation()
    }

    /// Stop `tunnel`.
    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.isWaiting = false
        tunnel.startDeactivation()
    }

    // MARK: - Status routing

    private func handleStatusNotification(_ object: Any?) {
        guard
            let connection = object as? NEVPNConnection,
            let manager = connection.manager as? NETunnelProviderManager,
            let id = TunnelContainer.profileID(of: manager),
            let tunnel = tunnels.first(where: { $0.id == id })
        else { return }

        if connection.status == .disconnected {
            // Fire a pending waiter (a tunnel queued behind this one), then
            // handle a self-restart (config change / add knockdown).
            let onDeactivated = tunnel.onDeactivated
            tunnel.onDeactivated = nil
            onDeactivated?()

            if tunnel.isRestarting {
                tunnel.isRestarting = false
                Task { await tunnel.startActivation() }
                return
            }
        }
        tunnel.refreshStatus()
    }

    // MARK: - Helpers

    /// iOS deactivates the active tunnel when a new manager is saved; bring the
    /// previously active one back. If it's already fully down, start it now;
    /// otherwise mark it restarting so the status observer restarts it once it
    /// reaches `.disconnected`.
    private func restoreAfterAddDeactivation(_ activeTunnel: TunnelContainer?) {
        guard let activeTunnel else { return }
        if activeTunnel.manager.connection.status == .disconnected {
            Task { await activeTunnel.startActivation() }
        } else {
            activeTunnel.isRestarting = true
        }
    }

    private func makeProtocol(for profile: TunnelProfile) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        // serverAddress is shown in Settings > VPN; node id is fine here.
        proto.serverAddress = profile.serverNodeID
        proto.providerConfiguration = profile.providerConfiguration()
        return proto
    }

    private func validatedName(_ raw: String, excluding: TunnelContainer?) throws -> String {
        let others = tunnels.filter { $0.id != excluding?.id }.map(\.name)
        switch validateTunnelName(raw, existing: others) {
        case .success(let name): return name
        case .failure(.empty): throw TunnelsManagerError.nameEmpty
        case .failure(.duplicate): throw TunnelsManagerError.nameDuplicate
        }
    }
}
