# Architecture & operations

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
                                    │  stopTunnel: ezvpn_stop      │     + stream loop)
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
- A stale extension is detected while connected: the app sends provider
  message byte 2 and compares the running extension's `BundleVersion` with its
  own (every target shares one version). On a mismatch, or no reply from an
  extension that predates the query, the profile list and menu bar warn and
  offer "Update extension", which resubmits the activation request so sysextd
  replaces the old extension. Reconnecting alone does not help: the extension
  process outlives tunnel sessions.
- Regenerate the project (`xcodegen generate`) after editing `project.yml`. The
  `.xcodeproj` is git-ignored on purpose.
