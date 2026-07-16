#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ezvpn"
PROJECT_NAME="Ezvpn"
SCHEME="Ezvpn"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/create-archive-macos.sh [TEAM_ID] [options]
  scripts/create-archive-macos.sh --team-id <TEAM_ID> [options]

Builds a macOS .xcarchive and exports it to a signed .app in one step.
Defaults to development ("debugging") signing, matching create-archive-ios.sh
and run-macos.sh: the exported .app runs on provisioned/development machines.
(A Developer ID network-extension app must ship the tunnel as a System
Extension, not the current app extension, so -m developer-id will not export.)

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -a, --archive-path PATH     Output path for the macOS .xcarchive.
                              Defaults to ./build/${APP_NAME}-macos.xcarchive.
  -c, --configuration NAME    Build configuration. Defaults to Release.
  -o, --export-path PATH      Output directory for the exported .app.
                              Defaults to ./build/export-macos.
  -m, --method METHOD         Export method. Defaults to debugging.
  -h, --help                  Show this help.

Both build steps (archive and export) run with -allowProvisioningUpdates so
Xcode can create or update the development signing profiles the Packet Tunnel
network-extension entitlement needs (mirrors scripts/run-macos.sh). That path
is NOT offline or non-mutating: it requires an Apple Developer account signed
in to Xcode and network access to Apple, and it may create or modify signing
assets on the developer portal. Where credentials or network are unavailable
(e.g. locked-down CI), pre-install the required profiles/certificates and drop
the two -allowProvisioningUpdates flags below, or feed in a pre-signed archive;
the default leaves them on.

Environment overrides:
  TEAM_ID, ARCHIVE_PATH, CONFIGURATION, EXPORT_PATH, METHOD
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}-macos.xcarchive}"
CONFIGURATION="${CONFIGURATION:-Release}"
EXPORT_PATH="${EXPORT_PATH:-$PROJECT_ROOT/build/export-macos}"
METHOD="${METHOD:-debugging}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TEAM_ID="$2"
      shift 2
      ;;
    -a|--archive-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    -c|--configuration)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    -o|--export-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      EXPORT_PATH="$2"
      shift 2
      ;;
    -m|--method)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      METHOD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "$TEAM_ID" ]]; then
        usage >&2
        die "unexpected argument: $1"
      fi
      TEAM_ID="$1"
      shift
      ;;
  esac
done

detect_project_team_id() {
  local xcconfig="$PROJECT_ROOT/Developer.local.xcconfig"
  [[ -f "$xcconfig" ]] || return 1

  /usr/bin/awk '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      sub(/\/\/.*$/, "")
      sub(/.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]"]+$/, "")
      gsub(/^[[:space:]"]+/, "")
      if ($0 != "") {
        print $0
        found = 1
        exit 0
      }
    }
    END { if (!found) exit 1 }
  ' "$xcconfig"
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_project_team_id || true)"
fi

[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig (copy Developer.local.xcconfig.sample) or pass --team-id"
}

[[ "$ARCHIVE_PATH" == *.xcarchive ]] || die "--archive-path must end in .xcarchive"

[[ -e "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" ]] || \
  die "${PROJECT_NAME}.xcodeproj not found — run 'xcodegen generate' first"

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

# Clear both outputs up front so a failure mid-flight cannot leave a stale
# .app from a previous run sitting next to a new (or missing) .xcarchive.
if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Replacing existing archive: $ARCHIVE_PATH"
  /bin/rm -rf "$ARCHIVE_PATH"
fi

if [[ -e "$EXPORT_PATH" ]]; then
  echo "Replacing existing export directory: $EXPORT_PATH"
  /bin/rm -rf "$EXPORT_PATH"
fi

echo "Creating macOS archive:"
printf '  archive:       %s\n' "$ARCHIVE_PATH"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  team:          %s\n' "$TEAM_ID"

# generic/platform=macOS + -sdk macosx selects the native macos-arm64 slice of
# the two-platform libezvpn.xcframework (see CLAUDE.md).
xcodebuild archive \
  -project "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -sdk macosx \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID"

/bin/mkdir -p "$EXPORT_PATH"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-export.XXXXXX")"
cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :method string $METHOD" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"

echo "Exporting archive:"
printf '  archive: %s\n' "$ARCHIVE_PATH"
printf '  export:  %s\n' "$EXPORT_PATH"
printf '  method:  %s\n' "$METHOD"
printf '  team:    %s\n' "$TEAM_ID"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates
