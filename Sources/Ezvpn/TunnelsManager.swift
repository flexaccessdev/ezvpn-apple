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
/// (the app runs at most one tunnel at a time), and routes system status
/// notifications to the right container.
@MainActor
final class TunnelsManager: ObservableObject {
    @Published private(set) var tunnels: [TunnelContainer] = []
    @Published private(set) var menuBarIconState: MenuBarIconState = .disconnected
    @Published var lastError: String?

    /// Bundle id of the Packet Tunnel extension. It is always the app's own
    /// bundle id plus the ".PacketTunnel" suffix (see PRODUCT_BUNDLE_IDENTIFIER
    /// in project.yml), so deriving it from Bundle.main keeps it correct under
    /// any $(BUNDLE_ID_PREFIX) the build was signed with — no hardcoded prefix.
    private let providerBundleID = Bundle.main.bundleIdentifier! + ".PacketTunnel"

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
    /// survive) and dropping any removed outside the app. Managers without the
    /// current stable-id + Keychain-reference format are ignored.
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
            refreshMenuBarIconState()
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
    func add(_ profile: TunnelProfile, authToken: String) async throws -> TunnelContainer {
        let name = try validatedName(profile.name, excluding: nil)
        var profile = profile
        profile.name = name

        let activeTunnel = tunnels.first { $0.status.isInOperation }

        let passwordReference: Data
        do {
            passwordReference = try AuthTokenKeychain.store(
                authToken, for: profile.id)
        } catch {
            throw TunnelsManagerError.system(error)
        }

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = makeProtocol(
            for: profile, passwordReference: passwordReference)
        manager.localizedDescription = name
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            // Roll back the token stored for this never-saved profile. Its id is
            // a fresh UUID no saved profile references, so a swallowed delete
            // failure would leak the Keychain item forever — surface it instead.
            do {
                try AuthTokenKeychain.delete(for: profile.id)
            } catch let rollbackError {
                throw compoundSystemError(primary: error, rollback: [rollbackError])
            }
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
        refreshMenuBarIconState()
        return container
    }

    /// Rewrite an existing profile's configuration and/or name. If it is running
    /// and the config changed, restart it so the change takes effect.
    func modify(
        _ tunnel: TunnelContainer,
        to profile: TunnelProfile,
        authToken: String
    ) async throws {
        let name = try validatedName(profile.name, excluding: tunnel)
        var profile = profile
        profile.name = name

        // Read the existing token before any mutation so a rollback can restore
        // it. A genuinely absent token (nothing to restore) is fine; a read
        // failure must abort before we touch the Keychain or preferences.
        let previousToken: String?
        do {
            previousToken = try tunnel.authToken()
        } catch AuthTokenKeychainError.missingPersistentReference {
            previousToken = nil
        } catch {
            throw TunnelsManagerError.system(error)
        }
        let passwordReference: Data
        do {
            passwordReference = try AuthTokenKeychain.store(
                authToken, for: profile.id)
        } catch {
            throw TunnelsManagerError.system(error)
        }

        tunnel.manager.protocolConfiguration = makeProtocol(
            for: profile, passwordReference: passwordReference)
        tunnel.manager.localizedDescription = name
        tunnel.manager.isEnabled = true
        do {
            try await tunnel.manager.saveToPreferences()
            try await tunnel.manager.loadFromPreferences()
        } catch {
            // Best-effort rollback of both the Keychain token and the in-memory
            // manager config; attempt both, but surface any rollback failure
            // instead of hiding it. The preference failure stays the primary.
            var rollbackErrors: [Error] = []
            do {
                if let previousToken {
                    _ = try AuthTokenKeychain.store(previousToken, for: profile.id)
                } else {
                    try AuthTokenKeychain.delete(for: profile.id)
                }
            } catch let rollbackError {
                rollbackErrors.append(rollbackError)
            }
            do {
                try await tunnel.manager.loadFromPreferences()
            } catch let rollbackError {
                rollbackErrors.append(rollbackError)
            }
            if rollbackErrors.isEmpty {
                throw TunnelsManagerError.system(error)
            }
            throw compoundSystemError(primary: error, rollback: rollbackErrors)
        }
        tunnel.setName(name)
        tunnels.sort { tunnelNameIsLessThan($0.name, $1.name) }

        if tunnel.status.isInOperation {
            tunnel.isRestarting = true
            tunnel.startDeactivation()
        }
        refreshMenuBarIconState()
    }

    /// Delete a profile and its saved VPN configuration.
    func remove(_ tunnel: TunnelContainer) async throws {
        do {
            try await tunnel.manager.removeFromPreferences()
        } catch {
            throw TunnelsManagerError.system(error)
        }
        tunnels.removeAll { $0.id == tunnel.id }
        refreshMenuBarIconState()
        do {
            try AuthTokenKeychain.delete(for: tunnel.id)
        } catch {
            throw TunnelsManagerError.system(error)
        }
    }

    /// Combine a primary failure with one or more rollback failures so the
    /// rollback problem is surfaced rather than silently dropped, while the
    /// primary failure stays the root cause (both localized and chained).
    private func compoundSystemError(
        primary: Error, rollback rollbackErrors: [Error]
    ) -> TunnelsManagerError {
        let detail = rollbackErrors
            .map { $0.localizedDescription }
            .joined(separator: "; ")
        let combined = NSError(domain: "ezvpn", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "\(primary.localizedDescription) "
                + "Rolling back the change also failed: \(detail)",
            NSUnderlyingErrorKey: primary as NSError,
        ])
        return .system(combined)
    }

    // MARK: - Activation

    /// Start `tunnel`, first tearing down any other active tunnel and waiting
    /// for it to fully stop.
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
            refreshMenuBarIconState()
            return
        }
        await tunnel.startActivation()
        refreshMenuBarIconState()
    }

    /// Stop `tunnel`.
    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.isWaiting = false
        tunnel.startDeactivation()
        refreshMenuBarIconState()
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
                refreshMenuBarIconState()
                return
            }
        }
        tunnel.refreshStatus()
        refreshMenuBarIconState()
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

    private func makeProtocol(
        for profile: TunnelProfile,
        passwordReference: Data
    ) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        // serverAddress is shown in Settings > VPN; node id is fine here.
        proto.serverAddress = profile.serverNodeID
        proto.providerConfiguration = profile.providerConfiguration()
        proto.passwordReference = passwordReference
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

    private func refreshMenuBarIconState() {
        menuBarIconState = .resolve(statuses: tunnels.map { $0.manager.connection.status })
    }
}
