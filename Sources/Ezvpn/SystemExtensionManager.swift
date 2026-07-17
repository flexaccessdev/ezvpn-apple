#if os(macOS)
import Foundation
import SystemExtensions

/// Lifecycle state of the packet-tunnel system extension, surfaced to the UI.
enum SystemExtensionState: Equatable {
    case idle
    case activating
    /// The request is parked in the system waiting for the user to approve the
    /// extension in System Settings. The delegate fires again once they do.
    case needsApproval
    case active
    case failed(String)
}

/// Drives installation/activation of the packet-tunnel **system extension** —
/// the packaging a Developer-ID-signed network extension must use on macOS (see
/// the `PacketTunnelSysEx` target in project.yml). Unlike the iOS app extension,
/// which the system loads on demand, a system extension must be explicitly
/// activated by its containing app and approved by the user before any
/// `NETunnelProviderManager` pointing at it can start. The app submits the
/// request at launch and reports progress back through `onStateChange`.
///
/// Activation only succeeds for a Developer-ID-signed app running from
/// /Applications (or a development build with `systemextensionsctl developer on`).
@MainActor
final class SystemExtensionManager: NSObject {
    private let extensionIdentifier: String
    private let onStateChange: (SystemExtensionState) -> Void

    init(
        extensionIdentifier: String,
        onStateChange: @escaping (SystemExtensionState) -> Void
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.onStateChange = onStateChange
        super.init()
    }

    /// Submit an activation request for the packet-tunnel extension. Safe to
    /// call repeatedly: resubmitting an already-active, unchanged extension
    /// simply reports `.active` again.
    func activate() {
        onStateChange(.activating)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    // Callbacks arrive on the `.main` queue passed to the request; hop onto the
    // MainActor to mutate the manager's isolated state.

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always install the version bundled in this app, whether it is newer,
        // older, or identical — the app and its extension ship together.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.onStateChange(.needsApproval) }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        // .completed and .willCompleteAfterReboot both mean the extension is (or
        // will be) installed; treat both as active.
        Task { @MainActor in self.onStateChange(.active) }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Task { @MainActor in self.onStateChange(.failed(error.localizedDescription)) }
    }
}
#endif
