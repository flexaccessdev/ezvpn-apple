// Exposes the Rust library's C API (libezvpn.xcframework) to the app target.
// The app only calls the key primitives — ezvpn_generate_client_key and
// ezvpn_client_public_key — so the flexaccess ed25519 key format is never
// reimplemented in Swift; the tunnel functions are used by the packet-tunnel
// targets (see Sources/PacketTunnel/Bridging-Header.h). The header is delivered
// by the Ezvpn Swift package's binary target; SPM puts its embedded Headers/
// dir on the search path, so this resolves with no HEADER_SEARCH_PATHS.
#import "ezvpn.h"
