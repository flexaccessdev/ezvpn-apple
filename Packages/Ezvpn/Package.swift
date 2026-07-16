// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the Apple Rust artifact — libezvpn.xcframework (built by the sibling
// repo's build-apple.sh, released as libezvpn-apple.xcframework.zip) — as a Swift
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
// ../ezvpn/dist/apple/libezvpn.xcframework. Set the var to "1" to use that
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
    url: "https://github.com/andrewtheguy/ezvpn/releases/download/v0.0.20/libezvpn-apple.xcframework.zip",
    checksum: "497cc50c2640ca50d0df32e44997ff4cc8c7bf3feb251842a521d2c08fcc2214"
)

let package = Package(
    name: "Ezvpn",
    products: [
        .library(name: "libezvpn", targets: ["libezvpn"]),
    ],
    targets: [binaryTarget]
)
