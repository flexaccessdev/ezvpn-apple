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
        #else
        autocorrectionDisabled()
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

/// Trim surrounding whitespace/newlines.
func trimmed(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Split a comma-separated field into trimmed, non-empty entries.
func splitCSV(_ s: String) -> [String] {
    s.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
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
