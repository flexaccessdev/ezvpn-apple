# Building & running

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
   artifact. For iOS, select a physical device in Xcode or use
   `scripts/run-device-ios.sh <DEVICE_ID>`. The OS prompts to allow the VPN
   configuration on first connect.

   > **Activating the macOS system extension in Debug.** macOS refuses to
   > activate a development-signed system extension unless the containing app
   > runs from `/Applications`. Straight from DerivedData you get:
   >
   > ```
   > Couldn't install the network extension: App containing System Extension
   > to be activated must be in /Applications folder. Current location: …/DerivedData/…/ezvpn.app
   > ```
   >
   > Two ways to get past it:
   >
   > - **Enable developer mode (best for iterating).** Lets the extension
   >   activate from DerivedData, so you keep running `scripts/run-macos.sh`
   >   unchanged. Persists across reboots until turned off:
   >
   >   ```sh
   >   systemextensionsctl developer on   # off to revert
   >   ```
   >
   > - **Run from `/Applications`.** `scripts/run-macos.sh --install` copies the
   >   built app to `/Applications/ezvpn.app` and launches it from there.
   >
   > Either way, approve the extension in *System Settings → Privacy & Security*
   > on first activation.
   >
   > **Iterating on extension code:** `sysextd` will not replace an installed
   > extension that has the same version, so the old binary silently keeps
   > running. Bump `CURRENT_PROJECT_VERSION` in `project.yml` whenever you change
   > extension code (the run script re-runs `xcodegen generate` for you).
   > Inspect what is registered with `systemextensionsctl list`.

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

## Unit tests

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
