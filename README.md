# ezvpn-ios (POC)

A minimal iOS app + Packet Tunnel extension that runs the [`ezvpn`](../ezvpn)
IP-over-QUIC tunnel on-device. **POC scope:** IPv4 **private split tunnel**
only, real-device testing only, no App Store preparation.

It links `libezvpn.a` (the Rust core, built from the sibling `../ezvpn` repo)
into a `NEPacketTunnelProvider`. The Rust side does the iroh connect + handshake
+ datagram loop; iOS owns the `utun` interface, routing, and IP/MTU config.

## What this POC does and does not do

- ✅ IPv4 split tunnel to private CIDRs (e.g. `10.0.0.0/8`).
- ✅ Connects to an `ezvpn` server over iroh (direct or relay), handshakes,
  tunnels IP over QUIC datagrams.
- ❌ No IPv6, no full tunnel, no underlay-bypass routing (a private split tunnel
  never captures the iroh underlay, so it isn't needed).
- ❌ No App Store / TestFlight setup. No simulator (a Packet Tunnel Provider
  only runs on a real device).
  
## Prerequisites

- **Paid Apple Developer account.** The Network Extension (`packet-tunnel-provider`)
  capability is not available on free personal teams. Both the app and the
  extension App IDs need the *Network Extensions* capability enabled (Xcode's
  automatic signing will offer to add it, or enable it in the Developer portal).
- Xcode (tested with 26.2) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS target: `rustup target add aarch64-apple-ios`.

## Build & run

1. **Build the Rust static library** (from the sibling repo). This stages
   `vendor/libezvpn.a` and `vendor/ezvpn.h` here automatically:

   ```sh
   cd ../ezvpn
   ./build-ios.sh release
   ```

2. **Generate the Xcode project:**

   ```sh
   cd ../ezvpn-ios
   xcodegen generate
   open Ezvpn.xcodeproj
   ```

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
   - *Auth token* — optional, if the server requires one.
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
│  start/stop             │        │   ezvpn_connect(json) ───────┼──▶ libezvpn.a
└─────────────────────────┘        │   setTunnelNetworkSettings   │    (iroh connect
                                    │   ezvpn_run(utun_fd) ────────┼──▶  + handshake
                                    │  stopTunnel: ezvpn_stop      │     + datagram loop)
                                    └──────────────────────────────┘
```

The C boundary is `vendor/ezvpn.h` (three calls: `ezvpn_connect` →
`ezvpn_run` → `ezvpn_stop`). See the header for the JSON config/result shapes.

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
