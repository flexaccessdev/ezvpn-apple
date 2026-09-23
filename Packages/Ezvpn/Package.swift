// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the Apple Rust artifact — libezvpn.xcframework (built by the sibling
// repo's build-apple.sh, released as libezvpn-apple.xcframework.zip) — as a Swift
// package binary target. The app (this repo) references this package by local
// path, so it always uses this manifest; there is no vendored copy.
//
// Default: download the pinned release zip by URL + checksum (reproducible).
// Bump the artifact pin with scripts/bump-xcframework.sh <tag>; it also updates
// the core version shown in the app's footer (project.yml EZVPN_CORE_VERSION).
// The app's own MARKETING_VERSION is independent and is not touched.
//
// Local FFI dev: set EZVPN_LOCAL_XCFRAMEWORK=1 to link a locally built
// xcframework instead of the release. SPM forbids binary-target paths outside
// the package root, so the local build is reached through the committed relative
// symlink local/libezvpn.xcframework, which points at sibling
// ../ezvpn/dist/apple/libezvpn.xcframework. All other values use the pinned
// release:
//   EZVPN_LOCAL_XCFRAMEWORK=1 ./scripts/run-macos.sh
// The run scripts already default to local and scope the setting across project
// generation and the build. If invoking the tools manually, prefix both:
//   EZVPN_LOCAL_XCFRAMEWORK=1 xcodegen generate
//   EZVPN_LOCAL_XCFRAMEWORK=1 xcodebuild ...

func localBinaryTarget() -> Target? {
    guard ProcessInfo.processInfo.environment["EZVPN_LOCAL_XCFRAMEWORK"] == "1"
    else { return nil }
    return .binaryTarget(name: "libezvpn", path: "local/libezvpn.xcframework")
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libezvpn",
    url: "https://github.com/flexaccessdev/ezvpn/releases/download/v0.0.51/libezvpn-apple.xcframework.zip",
    checksum: "2d0efd9d0bacd441e020de0badf6a282e7ac82fc2d2dd7e69f2de6838c9186d4"
)

let package = Package(
    name: "Ezvpn",
    products: [
        .library(name: "libezvpn", targets: ["libezvpn"]),
    ],
    targets: [binaryTarget]
)
