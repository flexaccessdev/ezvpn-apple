// Exposes the Rust library's C API (libezvpn.xcframework) to Swift. The header
// is delivered by the Ezvpn Swift package's binary target; SPM puts its embedded
// Headers/ dir on the search path, so this resolves with no HEADER_SEARCH_PATHS.
#import "ezvpn.h"
