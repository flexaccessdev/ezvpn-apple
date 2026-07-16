#!/usr/bin/env bash
set -euo pipefail

# Build and launch the native macOS app and Packet Tunnel app extension.
# Local Rust XCFramework is the default; pass --pinned for the release artifact.

PROJECT_NAME="Ezvpn"
SCHEME="EzvpnApp"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/run-macos.sh [options]

Builds and opens the native macOS EzvpnApp with automatic development signing.

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -c, --configuration NAME    Build configuration. Defaults to Debug.
      --pinned                Link the released xcframework instead of the local
                              ../ezvpn/dist/apple build.
      --install               Copy the built app to /Applications before opening it.
  -h, --help                  Show this help.

Environment overrides:
  TEAM_ID, CONFIGURATION
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

detect_project_team_id() {
  local xcconfig="$PROJECT_ROOT/Developer.local.xcconfig"
  [[ -f "$xcconfig" ]] || return 1
  /usr/bin/awk '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      sub(/\/\/.*/, "")
      sub(/.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]"]+$/, ""); gsub(/^[[:space:]"]+/, "")
      if ($0 != "") { print $0; found = 1; exit 0 }
    }
    END { if (!found) exit 1 }
  ' "$xcconfig"
}

TEAM_ID="${TEAM_ID:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"
USE_LOCAL_XCFRAMEWORK=1
INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TEAM_ID="$2"; shift 2 ;;
    -c|--configuration)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CONFIGURATION="$2"; shift 2 ;;
    --pinned)  USE_LOCAL_XCFRAMEWORK=0; shift ;;
    --install) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; die "unknown option: $1" ;;
    *)         usage >&2; die "unexpected argument: $1" ;;
  esac
done

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_project_team_id || true)"
fi
[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig or pass --team-id"
}

if [[ "$USE_LOCAL_XCFRAMEWORK" == "1" ]]; then
  link="$PROJECT_ROOT/Packages/Ezvpn/local/libezvpn.xcframework"
  [[ -e "$link" ]] || die "local xcframework not found at $link — build it with '(cd ../ezvpn && ./build-apple.sh release)'"
  export EZVPN_LOCAL_XCFRAMEWORK=1
else
  unset EZVPN_LOCAL_XCFRAMEWORK || true
fi

command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
echo "Generating project (local xcframework: $USE_LOCAL_XCFRAMEWORK) ..."
( cd "$PROJECT_ROOT" && xcodegen generate )

DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}/${SCHEME}.app"

echo "Building ${SCHEME} for macOS:"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  team:          %s\n' "$TEAM_ID"

( cd "$PROJECT_ROOT" && xcodebuild build \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" )

[[ -d "$APP_PATH" ]] || die "build did not produce an app at $APP_PATH"

if [[ "$INSTALL" == "1" ]]; then
  INSTALL_PATH="/Applications/${SCHEME}.app"
  if [[ -e "$INSTALL_PATH" ]]; then
    /bin/rm -rf "$INSTALL_PATH"
  fi
  /usr/bin/ditto "$APP_PATH" "$INSTALL_PATH"
  APP_PATH="$INSTALL_PATH"
  echo "Installed $APP_PATH"
fi

echo "Opening $APP_PATH ..."
/usr/bin/open "$APP_PATH"

echo
echo "If the Packet Tunnel extension does not appear, inspect registered providers with:"
echo "  pluginkit -m -p com.apple.networkextension.packet-tunnel"
echo "If DerivedData registration fails, retry with scripts/run-macos.sh --install."
