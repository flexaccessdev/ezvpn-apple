import SwiftUI
import NetworkExtension

extension NEVPNStatus {
    var displayText: String {
        switch self {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reasserting, .disconnecting: return .orange
        case .invalid, .disconnected: return Color.gray.opacity(0.35)
        @unknown default: return Color.gray.opacity(0.35)
        }
    }
}

extension View {
    /// Shared text-entry behavior with the UIKit-only capitalization modifier
    /// applied only where it exists.
    @ViewBuilder
    func fieldStyle() -> some View {
        #if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .multilineTextAlignment(.leading)
            .lineLimit(1)
        #else
        // In a grouped Form macOS reserves a label column for the TextField's
        // (empty) title and butts the control against it on the right, so short
        // text sits flush right. We already show our own label via LabeledField,
        // so hide the built-in one: the control then fills the row and left-aligns.
        //
        // The default plain style renders borderless in a grouped Form — the field
        // looks like static text and gives no visible click target to focus. A
        // rounded border draws an obvious box that fills the row and is easy to
        // click anywhere inside.
        autocorrectionDisabled()
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .lineLimit(1)
            .textFieldStyle(.roundedBorder)
        #endif
    }

    /// Keep iOS sheet titles compact without using the unavailable macOS API.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// App version pulled from the bundle: "vMARKETING (BUILD)" — e.g. "v0.0.30 (12)".
/// `CFBundleShortVersionString` is the marketing version, `CFBundleVersion` the
/// build number; both come from project.yml (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
enum AppVersion {
    static var displayString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "v\(marketing) (\(build))"
    }
}

/// Version label anchored at the bottom of the home screen. Tertiary caption so
/// it reads as a footnote and doesn't compete with the profile list.
struct VersionFooter: View {
    var body: some View {
        Text(AppVersion.displayString)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityLabel(Text("App version \(AppVersion.displayString)"))
    }
}

/// One row of the Active-routes debug section: a caption title over the CIDR
/// list, monospaced, one per line; "none" when the list is empty (an empty
/// bypass list is itself a useful signal — nothing was carved out).
struct RouteRow: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("none")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                Text(values.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A form row whose label stays visible above the field even after the field
/// has content — unlike a placeholder, which disappears once the user types.
struct LabeledField<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.vertical, 2)
    }
}
