import Foundation

/// Why a proposed profile name is unacceptable.
public enum TunnelNameError: Error, Equatable {
    /// Empty after trimming whitespace.
    case empty
    /// Case-insensitively equal to an existing profile's name.
    case duplicate
}

/// Validate a profile name against the existing names, returning the trimmed
/// name on success. `excluding` is the current name of the profile being renamed
/// (so a profile can keep its own name); pass nil when adding a new profile.
/// Comparison is case/diacritic/width/numeric-insensitive, matching
/// `tunnelNameIsLessThan` so "Home" and "home" can't both exist.
public func validateTunnelName(
    _ raw: String,
    existing: [String],
    excluding excludedName: String? = nil
) -> Result<String, TunnelNameError> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.empty) }

    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    if let excludedName, trimmed.compare(excludedName, options: options) == .orderedSame {
        return .success(trimmed)
    }
    for name in existing where trimmed.compare(name, options: options) == .orderedSame {
        return .failure(.duplicate)
    }
    return .success(trimmed)
}

/// Sort comparator for the tunnel list: the same case/diacritic/width/numeric-
/// insensitive ordering the WireGuard app uses, so e.g. "tunnel2" sorts before
/// "tunnel10".
public func tunnelNameIsLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(
        rhs,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric]
    ) == .orderedAscending
}
