# ezvpn-ios

A universal native iOS + macOS SwiftUI app and Packet Tunnel app extension that
runs the [`ezvpn`](../ezvpn) IP-over-QUIC tunnel. **Scope:** dual-stack **split
tunnel** with optional tunnel DNS, development-signed personal use, and no App
Store or Developer ID preparation.

It links `libezvpn.xcframework` (the Rust core, built from the sibling `../ezvpn`
repo and delivered via a local Swift package) into a `NEPacketTunnelProvider`.
The Rust side does the iroh connect + handshake + datagram loop; the Apple
Network Extension owns the `utun` interface, routing, and IP/MTU config.

## What this app does and does not do

- ✅ Multiple saved VPN profiles, WireGuard-app style: a tunnel list where each
  profile is its own `NETunnelProviderManager` (name shown in Settings > VPN).
  Add/edit/rename/delete profiles; connect one at a time (activating a second
  automatically tears down the first). All profiles share the one PacketTunnel
  extension — each carries its own config in `providerConfiguration`.
- ✅ IPv4/IPv6 split tunnel. The server gateway/interface routes are always
  routed automatically; extra IPv4 and IPv6 CIDRs are optional.
- ✅ Optional tunnel DNS on both platforms. iOS also exposes match domains for
  conditional forwarding because iOS ignores installed DNS profiles while a
  VPN is active. macOS keeps those profiles active, so its UI exposes only the
  global tunnel DNS servers field.
- ✅ Connects to an `ezvpn` server over iroh (direct or relay), handshakes,
  tunnels IP over QUIC datagrams.
- ✅ Underlay-bypass routing, like the desktop client's bootstrap bypass: at
  connect, the core computes every relay IP plus the server's candidate
  underlay addresses, and any **global-scope** address a routed prefix would
  capture is excluded from the tunnel (`excludedRoutes`), so the transport never
  self-captures. Private/LAN server addresses are intentionally kept in the
  tunnel. Static (handshake-time) only — the server's mid-session address
  publications are not re-applied.
- ✅ Simple manual connect/disconnect. Tunnel teardown follows wireguard-apple:
  `stopTunnel` completes only after the Rust data plane has actually stopped.
- ✅ On macOS, a native menu-bar icon provides quick profile connect/disconnect,
  main-window, and quit actions while the main window is closed.
- ✅ Disconnect on network change: any change to the physical network (Wi-Fi ↔
  cellular, different Wi-Fi, network lost) cancels the tunnel rather than trying
  to migrate the QUIC session across it — reconnect manually on the new network.
- ✅ Refuses to start when a configured split-tunnel route overlaps the local
  network's subnet (e.g. routing `192.168.0.0/16` while on a `192.168.1.0/24`
  Wi-Fi): capturing the on-link subnet would cut off the LAN, including the
  gateway carrying the tunnel's own underlay traffic.
- ✅ Debug: while connected, the app shows the *applied* interface state —
  assigned addresses, tunnel routes, active bypass (excluded) routes, and DNS
  settings — queried live from the tunnel process over the WireGuard-style
  runtime-configuration app message (single byte `0`). It can also show a live
  iroh connection-path snapshot (direct/relay paths) via app message byte `1`.
- ❌ No App Store, TestFlight, or Developer ID setup. The macOS debug flow uses
  a development-signed app extension; system extensions are needed only for
  Developer ID distribution. A Packet Tunnel Provider cannot run in the iOS
  Simulator.
  
## Prerequisites

- **Paid Apple Developer account.** The Network Extension (`packet-tunnel-provider`)
  capability is not available on free personal teams. Both the app and the
  extension App IDs need the *Network Extensions* capability enabled (Xcode's
  automatic signing will offer to add it, or enable it in the Developer portal).
  The development Mac must also be registered to the team before Xcode can mint
  its Mac App Development profiles.
- Xcode (tested with 26.2) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS and macOS targets (only for local FFI dev):
  `rustup target add aarch64-apple-ios aarch64-apple-darwin`.

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
   > of the release, build it in the sibling repo and set
   > `EZVPN_LOCAL_XCFRAMEWORK=1` (all other values select the pinned release):
   >
   > ```sh
   > cd ../ezvpn && ./build-apple.sh release && cd ../ezvpn-ios
   > EZVPN_LOCAL_XCFRAMEWORK=1 xcodegen generate
   > # …and pass the same env var to xcodebuild / Xcode when building.
   > ```
   >
   > SPM forbids binary paths outside the package root, so the sibling's
   > `dist/apple` is reached via the committed symlink
   > `Packages/Ezvpn/local/libezvpn.xcframework`.

2. **Set signing.** Select your Team on **both** targets (`EzvpnApp` and
   `PacketTunnel`) under *Signing & Capabilities*. For repeatable command-line
   builds, copy `Developer.local.xcconfig.sample` to
   `Developer.local.xcconfig`, set `DEVELOPMENT_TEAM`, and re-run
   `xcodegen generate`.

   If you change the bundle identifiers, update `providerBundleID` in
   `Sources/EzvpnApp/TunnelsManager.swift` to match the extension's id (it must
   be a prefix-child of the app id, e.g. `com.you.ezvpn` + `.PacketTunnel`).

3. **Run the app.** For macOS, build and open the native app with:

   ```sh
   scripts/run-macos.sh
   ```

   This uses the local XCFramework by default; pass `--pinned` for the release
   artifact or `--install` to copy the app to `/Applications` if the extension
   does not register from DerivedData. For iOS, select a physical device in
   Xcode or use `scripts/run-device-ios.sh <DEVICE_ID>`. The OS prompts to allow
   the VPN configuration on first connect.

4. **Add a profile** (tap `+`), fill in the details, Save, then toggle it on:
   - *Name* — a unique label for the profile (shown in the list and Settings > VPN).
   - *Server node id* — the `ezvpn` server's iroh endpoint id.
   - *Auth token* — required; the token the server authenticates you with.
   - *Relay URLs* — optional hints; leave blank to use iroh defaults.
   - *IPv4 routes* — optional comma-separated CIDRs to tunnel.
   - *IPv6 routes* — optional comma-separated CIDRs to tunnel.
   - *DNS servers* — optional comma-separated IP literals to use as tunnel DNS.
   - *Match domains* (iOS only) — optional comma-separated suffixes for split
     DNS. Leave blank with DNS servers set to send all DNS through those servers.

   Add as many profiles as you like; only one connects at a time.

   Run a reachable `ezvpn` server (see the `ezvpn` repo) configured with an
   IPv4 `network`, IPv6 `network6`, or both, and add routes covering the private
   resources you want to reach.

### Unit tests

The pure IP/CIDR logic (prefix overlap, netmask math, the split-tunnel vs
local-network conflict check) lives in the local package `Packages/TunnelCore`
so it can be tested natively on the Mac, outside the app and extension targets:

```sh
cd Packages/TunnelCore && swift test
```

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
                                    │  debug: ezvpn_conn_path      │
                                    └──────────────────────────────┘
```

The C boundary is `ezvpn.h`, delivered inside the xcframework. The main
lifecycle is `ezvpn_connect` → `ezvpn_run` → `ezvpn_stop`; the extension also
calls `ezvpn_init_logging`, and the debug UI can query `ezvpn_conn_path` for a
live direct/relay path snapshot. See the header for the JSON config/result
shapes.

## Logs

The extension logs to the unified log (subsystem
`com.example.ezvpn.PacketTunnel`). Watch with:

```sh
log stream --predicate 'subsystem == "com.example.ezvpn.PacketTunnel"' --level debug
```

Rust-side logs go to stderr (honors `RUST_LOG`, default `info`) and are captured
in the device or Mac log as well.

## Notes

- One benign linker warning (`blake3_neon.o was built for newer iOS version`)
  comes from a dependency's hand-written assembly object; it links and runs
  fine.
- If the macOS app extension does not appear, check for stale or duplicate
  providers with
  `pluginkit -m -p com.apple.networkextension.packet-tunnel`; retry
  `scripts/run-macos.sh --install` if DerivedData registration is the issue.
- Regenerate the project (`xcodegen generate`) after editing `project.yml`. The
  `.xcodeproj` is git-ignored on purpose.
