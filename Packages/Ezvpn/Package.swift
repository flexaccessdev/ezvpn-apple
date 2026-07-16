// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the Apple Rust artifact — libezvpn.xcframework (built by the sibling
// repo's build-apple.sh, released as libezvpn-apple.xcframework.zip) — as a Swift
// package binary target. The app (this repo) references this package by local
// path, so it always uses this manifest; there is no vendored copy.
//
// Default: download the pinned release zip by URL + checksum (reproducible).
// Bump the artifact pin and app/extension marketing versions together with
// scripts/bump-xcframework.sh <tag>.
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
    url: "https://github.com/flexaccessdev/ezvpn/releases/download/v0.0.20/libezvpn-apple.xcframework.zip",
    checksum: "b7d19d26b1ce424ca492e823af8dd9b55804e72f472556d561ecb162c506fa0e"
)

let package = Package(
    name: "Ezvpn",
    products: [
        .library(name: "libezvpn", targets: ["libezvpn"]),
    ],
    targets: [binaryTarget]
)
