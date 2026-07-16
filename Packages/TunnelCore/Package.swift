// swift-tools-version:5.9
import PackageDescription

// Pure IP/CIDR primitives shared with the PacketTunnel extension: CIDR
// parsing, prefix-overlap tests, netmask math, and the split-tunnel vs
// local-network conflict check. No NetworkExtension or FFI dependency — only
// Darwin — so the whole module builds and unit-tests natively on macOS
// (`swift test` in this directory), outside the host app and extension targets.
let package = Package(
    name: "TunnelCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
    ],
    targets: [
        .target(name: "TunnelCore"),
        .testTarget(name: "TunnelCoreTests", dependencies: ["TunnelCore"]),
    ]
)
