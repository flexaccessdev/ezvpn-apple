import NetworkExtension

/// Aggregate VPN state represented by the macOS menu-bar icon.
///
/// A reasserting session is still an established VPN that is recovering its
/// transport, so it retains the connected icon. Connecting and disconnecting
/// use the neutral icon until the system reports a stable state.
enum MenuBarIconState: Equatable {
    case disconnected
    case connected

    static func resolve(statuses: [NEVPNStatus]) -> MenuBarIconState {
        statuses.contains { $0 == .connected || $0 == .reasserting }
            ? .connected
            : .disconnected
    }

    var imageName: String {
        switch self {
        case .disconnected: "MenuBarIcon"
        case .connected: "MenuBarConnectedIcon"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .disconnected: "ezvpn, disconnected"
        case .connected: "ezvpn, connected"
        }
    }
}
