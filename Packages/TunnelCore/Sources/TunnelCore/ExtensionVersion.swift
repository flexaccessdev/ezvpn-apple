import Foundation

/// A bundle's version pair: `CFBundleShortVersionString` and `CFBundleVersion`.
/// The app and its packet-tunnel extension always carry the same pair (every
/// target in project.yml shares MARKETING_VERSION / CURRENT_PROJECT_VERSION),
/// so a running extension whose pair differs from the app's is a stale binary
/// the system has not replaced yet.
public struct BundleVersion: Equatable, Sendable, CustomStringConvertible {
    public let short: String
    public let build: String

    public init(short: String, build: String) {
        self.short = short
        self.build = build
    }

    /// Read from a bundle's Info.plist dictionary; nil when either key is missing.
    public init?(infoDictionary: [String: Any]?) {
        guard
            let short = infoDictionary?["CFBundleShortVersionString"] as? String,
            let build = infoDictionary?["CFBundleVersion"] as? String
        else { return nil }
        self.init(short: short, build: build)
    }

    /// e.g. "0.0.6 (6)".
    public var description: String { "\(short) (\(build))" }

    /// The provider's reply to the app's extension-version query.
    public var jsonData: Data {
        // A [String: String] dictionary always serializes.
        (try? JSONSerialization.data(withJSONObject: ["version": short, "build": build])) ?? Data()
    }

    /// Decode the provider's reply; nil when malformed.
    public init?(jsonData data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let short = object["version"] as? String,
            let build = object["build"] as? String
        else { return nil }
        self.init(short: short, build: build)
    }
}

/// Outcome of comparing the running packet-tunnel extension with the app.
public enum ExtensionVersionCheck: Equatable, Sendable {
    case match
    /// The running extension differs from the app. `running` is nil when it
    /// did not report a version at all — an extension built before the version
    /// query existed, so necessarily older than this app.
    case mismatch(running: BundleVersion?)
}

/// Compare the extension-version reply (nil when the extension answered
/// nothing) against the version this app expects the extension to be.
public func checkRunningExtension(expected: BundleVersion, reply: Data?) -> ExtensionVersionCheck {
    guard let reply, let running = BundleVersion(jsonData: reply) else {
        return .mismatch(running: nil)
    }
    return running == expected ? .match : .mismatch(running: running)
}
