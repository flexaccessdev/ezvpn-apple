// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the iOS Rust artifact — libezvpn.xcframework (built by the sibling
// repo's build-ios.sh, released as libezvpn-ios.xcframework.zip) — as a Swift
// package binary target. The app (this repo) references this package by local
// path, so it always uses this manifest; there is no vendored copy.
//
// Default: download the pinned release zip by URL + checksum (reproducible).
// Bump both when moving to a new release (scripts/bump-xcframework.sh <tag>).
//
// Local FFI dev: set EZVPN_LOCAL_XCFRAMEWORK to link a locally built xcframework
// instead of the release. SPM forbids binary-target paths outside the package
// root, so the local build is reached through the committed relative symlink
// local/libezvpn.xcframework points at sibling
// ../ezvpn/dist/ios/libezvpn.xcframework. Set the var to "1" to use that
// symlink, or to another path relative to this package dir:
//   EZVPN_LOCAL_XCFRAMEWORK=1 xcodegen generate && ... xcodebuild ...

func localBinaryTarget() -> Target? {
    guard let value = ProcessInfo.processInfo.environment["EZVPN_LOCAL_XCFRAMEWORK"],
          !value.isEmpty else { return nil }
    let path = (value == "1" || value == "true") ? "local/libezvpn.xcframework" : value
    return .binaryTarget(name: "libezvpn", path: path)
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libezvpn",
    url: "https://github.com/andrewtheguy/ezvpn/releases/download/v0.0.18/libezvpn-ios.xcframework.zip",
    checksum: "0a813343720990ac92ddf24c04c9afa5a60c5f0c8d76dbe3a075fce55da2d352"
)

let package = Package(
    name: "Ezvpn",
    products: [
        .library(name: "libezvpn", targets: ["libezvpn"]),
    ],
    targets: [binaryTarget]
)
