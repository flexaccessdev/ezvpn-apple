# ezvpn-ios (POC)

A minimal iOS app + Packet Tunnel extension that runs the [`ezvpn`](../ezvpn)
IP-over-QUIC tunnel on-device. **POC scope:** dual-stack **split tunnel**,
real-device testing only, no App Store preparation.

It links `libezvpn.xcframework` (the Rust core, built from the sibling `../ezvpn`
repo and delivered via a local Swift package) into a `NEPacketTunnelProvider`.
The Rust side does the iroh connect + handshake + datagram loop; iOS owns the
`utun` interface, routing, and IP/MTU config.

## What this POC does and does not do

- ✅ IPv4/IPv6 split tunnel. The tunnel's own subnet (from the server-assigned
  address + mask) is always routed automatically; extra CIDRs are optional.
- ✅ Connects to an `ezvpn` server over iroh (direct or relay), handshakes,
  tunnels IP over QUIC datagrams.
- ✅ Underlay-bypass routing, like the desktop client's bootstrap bypass: at
  connect, the core computes every relay IP plus the server's candidate
  underlay addresses, and any of them a routed prefix would capture is excluded
  from the tunnel (`excludedRoutes`), so the transport never self-captures.
  Static (handshake-time) only — the server's mid-session address publications
  are not re-applied.
- ✅ Simple manual connect/disconnect. Tunnel teardown follows wireguard-apple:
  `stopTunnel` completes only after the Rust data plane has actually stopped.
- ✅ Debug: while connected, the app shows the *applied* interface state —
  assigned addresses, tunnel routes, and the active bypass (excluded) routes —
  queried live from the tunnel process over the WireGuard-style
  runtime-configuration app message (single byte `0`).
- ❌ No App Store / TestFlight setup. No simulator (a Packet Tunnel Provider
  only runs on a real device).
  
## Prerequisites

- **Paid Apple Developer account.** The Network Extension (`packet-tunnel-provider`)
  capability is not available on free personal teams. Both the app and the
  extension App IDs need the *Network Extensions* capability enabled (Xcode's
  automatic signing will offer to add it, or enable it in the Developer portal).
- Xcode (tested with 26.2) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS target (only for local FFI dev): `rustup target add aarch64-apple-ios`.

## Build & run

The Rust core is delivered as `libezvpn.xcframework` via a local Swift package
(`Packages/Ezvpn`). Its binary target **downloads the pinned release zip by
URL+checksum** by default — no local Rust build required. Bump to a newer
`ezvpn` release with `scripts/bump-xcframework.sh <tag>` (rewrites the URL and
checksum in `Packages/Ezvpn/Package.swift`).

1. **Generate the Xcode project** (SPM fetches the pinned xcframework):

   ```sh
   cd ../ezvpn-ios
   xcodegen generate
   open Ezvpn.xcodeproj
   ```

   > **Local FFI dev** — to build against a locally compiled Rust core instead
   > of the release, build it in the sibling repo and set `EZVPN_LOCAL_XCFRAMEWORK`:
   >
   > ```sh
   > cd ../ezvpn && ./build-ios.sh release && cd ../ezvpn-ios
   > EZVPN_LOCAL_XCFRAMEWORK=1 xcodegen generate
   > # …and pass the same env var to xcodebuild / Xcode when building.
   > ```
   >
   > SPM forbids binary paths outside the package root, so the sibling's
   > `dist/ios` is reached via the committed symlink
   > `Packages/Ezvpn/local/libezvpn.xcframework`.

3. **Set signing.** Select your Team on **both** targets (`EzvpnApp` and
   `PacketTunnel`) under *Signing & Capabilities*. You can also set
   `DEVELOPMENT_TEAM` in `project.yml` and re-run `xcodegen generate`.

   If you change the bundle identifiers, update `providerBundleID` in
   `Sources/EzvpnApp/VPNController.swift` to match the extension's id (it must
   be a prefix-child of the app id, e.g. `com.you.ezvpn` + `.PacketTunnel`).

4. **Run on a real device** (select your iPhone, not a simulator). On first
   connect, iOS prompts to allow the VPN configuration.

5. **Enter the server details** in the app and tap Connect:
   - *Server node id* — the `ezvpn` server's iroh endpoint id.
   - *Auth token* — required; the token the server authenticates you with.
   - *Relay URLs* — optional hints; leave blank to use iroh defaults.
   - *Routes* — the private CIDRs to tunnel (defaults to RFC1918).

   Run a reachable `ezvpn` server (see the `ezvpn` repo) configured with an
   IPv4 `network` and routes covering the private resources you want to reach.

## How it fits together

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│ EzvpnApp (SwiftUI)      │        │ PacketTunnel (extension)     │
│ NETunnelProviderManager │──VPN──▶│ NEPacketTunnelProvider       │
│  installs config,       │ config │  startTunnel:                │
│  start/stop             │        │   ezvpn_connect(json) ───────┼──▶ libezvpn
└─────────────────────────┘        │   setTunnelNetworkSettings   │    (iroh connect
                                    │   ezvpn_run(utun_fd) ────────┼──▶  + handshake
                                    │  stopTunnel: ezvpn_stop      │     + datagram loop)
                                    └──────────────────────────────┘
```

The C boundary is `ezvpn.h` (three calls: `ezvpn_connect` → `ezvpn_run` →
`ezvpn_stop`), delivered inside the xcframework. See the header for the JSON
config/result shapes.

## Logs

The extension logs to the unified log (subsystem
`com.example.ezvpn.PacketTunnel`). Watch with:

```sh
log stream --predicate 'subsystem == "com.example.ezvpn.PacketTunnel"' --level debug
```

Rust-side logs go to stderr (honors `RUST_LOG`, default `info`) and are captured
into the device log as well.

## Notes

- One benign linker warning (`blake3_neon.o was built for newer iOS version`)
  comes from a dependency's hand-written assembly object; it links and runs
  fine.
- Regenerate the project (`xcodegen generate`) after editing `project.yml`. The
  `.xcodeproj` is git-ignored on purpose.
