# ezvpn-apple

A universal native iOS + macOS SwiftUI app running the [`ezvpn`](../ezvpn)
IP-over-QUIC tunnel. The packet-tunnel provider ships as an **app extension on
iOS** and a **system extension on macOS** (the packaging Apple requires for
Developer ID distribution outside the App Store). **Scope:** dual-stack **split
tunnel**, optional tunnel DNS on iOS only, and macOS distribution via Developer
ID + notarization (`scripts/create-archive-macos.sh`).

It links `libezvpn.xcframework` (the Rust core, built from the sibling `../ezvpn`
repo and delivered via a local Swift package) into a `NEPacketTunnelProvider`.
The Rust side does the iroh connect + handshake + datagram loop; the Apple
Network Extension owns the `utun` interface, routing, and IP/MTU config.

## What this app does and does not do

- ✅ Multiple saved VPN profiles, WireGuard-app style: a tunnel list where each
  profile is its own `NETunnelProviderManager` (name shown in Settings > VPN).
  Add/edit/rename/delete profiles; connect one at a time (activating a second
  automatically tears down the first). All profiles share the one PacketTunnel
  extension. Non-secret settings live in `providerConfiguration`; the auth
  token is a device-only data-protection Keychain item shared with the extension
  through a keychain access group, and the VPN protocol stores only its
  persistent reference.
- ✅ IPv4/IPv6 split tunnel. The server gateway/interface routes are always
  routed automatically; extra IPv4 and IPv6 CIDRs are optional.
- ✅ Optional tunnel DNS on iOS, including match domains for conditional
  forwarding because iOS ignores installed DNS profiles while a VPN is active.
  The macOS build leaves the system's DNS configuration untouched.
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
  main-window, and quit actions. Closing the main window removes the Dock icon
  while leaving the menu-bar controls running; reopening restores both.
- ✅ Disconnect on network change: any change to the physical network (Wi-Fi ↔
  cellular, different Wi-Fi, network lost) cancels the tunnel rather than trying
  to migrate the QUIC session across it — reconnect manually on the new network.
- ✅ Refuses to start when a configured split-tunnel route overlaps the local
  network's subnet (e.g. routing `192.168.0.0/16` while on a `192.168.1.0/24`
  Wi-Fi): capturing the on-link subnet would cut off the LAN, including the
  gateway carrying the tunnel's own underlay traffic.
- ✅ Debug: while connected, the app shows the *applied* interface state —
  assigned addresses, tunnel routes, active bypass (excluded) routes, and on
  iOS, DNS settings — queried live from the tunnel process over the WireGuard-style
  runtime-configuration app message (single byte `0`). It can also show a live
  iroh connection-path snapshot (direct/relay paths) via app message byte `1`.
- ✅ macOS distribution for anyone, outside the App Store: the tunnel ships as a
  system extension and `scripts/create-archive-macos.sh` produces a Developer-ID-
  signed, notarized, stapled `.dmg`. The app activates the extension via
  `OSSystemExtensionRequest` at first launch (approved once in System Settings);
  activation requires the app to run from `/Applications`.
- ❌ No App Store or TestFlight submission. iOS still installs only via a
  development-signed build to a registered device. A Packet Tunnel Provider
  cannot run in the iOS Simulator.

## Prebuilt downloads (GitHub Releases)

The **Release (Manual)** workflow attaches **unsigned** app bundles to each
GitHub release, produced by `.github/workflows/build-unsigned.yml` with
`CODE_SIGNING_ALLOWED=NO` (so CI needs no signing secrets):

- `ezvpn-macos-unsigned.tar.gz` — the macOS `ezvpn.app` (Apple Silicon).
- `ezvpn-ios-unsigned.tar.gz` — the iOS `ezvpn.app` (`ios-arm64`, device only).

**These are not click-to-run downloads.** A Packet Tunnel Provider uses the
restricted `com.apple.developer.networking.networkextension` entitlement: the
system will not load the network extension unless the app *and* the extension
are signed with a provisioning profile that grants that capability, and on
macOS Gatekeeper blocks an unsigned bundle outright. The tarballs exist for
build verification and inspection — running the tunnel always requires signing
under a real team.

### What another developer has to do to run it

You must sign it under your **own** paid Apple Developer team (see
[Prerequisites](#prerequisites)), which means **building from source, not
re-signing the download** — the app's bundle id is compiled in, so it can't be
repointed inside a prebuilt bundle. The committed bundle-id prefix is the
placeholder `com.example.ezvpn` (registered to no team, so the release builds
are unsigned); the Network Extension needs explicit, non-wildcard App IDs your
team owns, so you supply your own prefix and build.

So follow [Build & run](#build--run): copy `Developer.local.xcconfig.sample` to
`Developer.local.xcconfig`, set your `DEVELOPMENT_TEAM` **and** a
`BUNDLE_ID_PREFIX` your team owns, `xcodegen generate`, then build with
`scripts/run-macos.sh` (macOS) or `scripts/run-device-ios.sh <DEVICE_ID>`
(iOS). Xcode signs it as it builds.

## Prerequisites

- **Paid Apple Developer account.** The Network Extension (`packet-tunnel-provider`)
  capability is not available on free personal teams. Both the app and the
  extension App IDs need the *Network Extensions* capability enabled (Xcode's
  automatic signing will offer to add it, or enable it in the Developer portal).
  Their provisioning profiles must also allow the shared Keychain access group.
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
checksum in `Packages/Ezvpn/Package.swift` and sets the app/extension marketing
versions to the release version).

1. **Generate the Xcode project** (SPM fetches the pinned xcframework):

   ```sh
   cd ../ezvpn-apple
   xcodegen generate
   open Ezvpn.xcodeproj
   ```

   > **Local FFI dev** — to build against a locally compiled Rust core instead
   > of the release, build it in the sibling repo and set
   > `EZVPN_LOCAL_XCFRAMEWORK=1` (all other values select the pinned release):
   >
   > ```sh
   > cd ../ezvpn && ./build-apple.sh release && cd ../ezvpn-apple
   > scripts/run-macos.sh
   > ```
   >
   > The run scripts default to the local artifact and keep the setting scoped
   > to their complete generate/build workflow; use `--pinned` to opt out. When
   > bypassing them, prefix both `xcodegen` and `xcodebuild` with
   > `EZVPN_LOCAL_XCFRAMEWORK=1`.
   >
   > SPM forbids binary paths outside the package root, so the sibling's
   > `dist/apple` is reached via the committed symlink
   > `Packages/Ezvpn/local/libezvpn.xcframework`.

2. **Set signing.** Select your Team on all three targets (`Ezvpn`,
   `PacketTunnel` [iOS app extension], and `PacketTunnelSysEx` [macOS system
   extension]) under *Signing & Capabilities*. For repeatable command-line
   builds, copy `Developer.local.xcconfig.sample` to
   `Developer.local.xcconfig`, set `DEVELOPMENT_TEAM`, and re-run
   `xcodegen generate`.

   The bundle-id prefix committed in `Developer.xcconfig` is the placeholder
   `com.example.ezvpn`, which signs under no team (it only builds unsigned). To
   sign, set `BUNDLE_ID_PREFIX` in the same `Developer.local.xcconfig` to a
   prefix your team owns — nothing else to edit: the app id, the `.PacketTunnel`
   extension id (shared by both the iOS app extension and the macOS system
   extension), and the id the app targets
   (`TunnelsManager.providerBundleID`, derived from `Bundle.main`) all follow it.
   (The keychain access group is `$(AppIdentifierPrefix)ezvpn.shared` — team-
   prefixed but otherwise a neutral constant, so it does not depend on the
   prefix.)

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
   - *DNS servers* (iOS only) — optional comma-separated IP literals to use as tunnel DNS.
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

App-model tests cover profile-editor conversion, packet-tunnel reply decoding,
VPN status presentation, and the `NETunnelProviderManager` profile wrapper. Run
them natively on the Mac after generating the project:

```sh
xcodegen generate
xcodebuild test -project Ezvpn.xcodeproj -scheme Ezvpn \
  -destination 'platform=macOS,arch=arm64'
```

## Distribute the macOS app (Developer ID)

`scripts/create-archive-macos.sh` builds, Developer-ID-signs, notarizes, staples,
and packages a drag-to-Applications `.dmg` that runs on any Mac — no App Store.

One-time Apple-side setup (the script cannot do these for you):

1. Create a **Developer ID Application** certificate: Xcode › Settings ›
   Accounts › Manage Certificates › **+** › *Developer ID Application*.
2. Create the two **manually managed Developer ID provisioning profiles** that
   `project.yml` pins by name for Release macOS builds — "ezvpn Developer ID
   app" (App ID `<prefix>`) and "ezvpn Developer ID sysex" (App ID
   `<prefix>.PacketTunnel`) — on the developer portal (Certificates,
   Identifiers & Profiles › Profiles › + › Developer ID, or via the App Store
   Connect API with an Admin key, `profileType: MAC_APP_DIRECT`). Once they
   exist, `-allowProvisioningUpdates` downloads them on any machine. They must
   be manually managed: Release macOS builds sign manually with Developer ID
   (automatic signing can only archive with a development identity, whose
   profile cannot carry the release entitlements'
   `packet-tunnel-provider-systemextension` value, and manual signing refuses
   Xcode-managed profiles).
3. Create an **App Store Connect API key** for notarization (App Store Connect ›
   Users and Access › Integrations › App Store Connect API) and download its
   `AuthKey_XXXX.p8`. Cache it as a notarytool profile once:

   ```sh
   xcrun notarytool store-credentials ezvpn-notary \
     --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
   ```

Then, with `DEVELOPMENT_TEAM` set in `Developer.local.xcconfig`:

```sh
xcodegen generate
scripts/create-archive-macos.sh --notary-profile ezvpn-notary
```

The result is `build/ezvpn-<version>.dmg`. Recipients drag **ezvpn** to
Applications, launch it, and approve the network extension once in System
Settings (the app requests activation on first launch). Pass `-m debugging`
instead for a local development-signed `.app` (no notarization or `.dmg`; runs
only on machines registered to your team). Run `--help` for all options.

## How it fits together

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│ Ezvpn (SwiftUI)         │        │ PacketTunnel (iOS) /         │
│ NETunnelProviderManager │──VPN──▶│ PacketTunnelSysEx (macOS)    │
│  installs config,       │ config │ NEPacketTunnelProvider       │
│  start/stop             │        │  startTunnel:                │
│                         │        │   ezvpn_connect(json) ───────┼──▶ libezvpn
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

The extension logs to the unified log under the fixed subsystem `ezvpn.PacketTunnel`
(a neutral constant, independent of the app's bundle id / `BUNDLE_ID_PREFIX`, so
it is the same whatever prefix you build under). Watch with:

```sh
log stream --predicate 'subsystem == "ezvpn.PacketTunnel"' --level debug
```

Rust-side logs go to stderr (honors `RUST_LOG`, default `info`) and are captured
in the device or Mac log as well.

## Notes

- One benign linker warning (`blake3_neon.o was built for newer iOS version`)
  comes from a dependency's hand-written assembly object; it links and runs
  fine.
- If the macOS system extension does not activate, list registered extensions
  with `systemextensionsctl list`. A development-signed build only activates from
  `/Applications` (retry `scripts/run-macos.sh --install`) or with
  `systemextensionsctl developer on`. Distributed (Developer ID + notarized)
  builds activate from `/Applications` with no developer mode.
- Regenerate the project (`xcodegen generate`) after editing `project.yml`. The
  `.xcodeproj` is git-ignored on purpose.
