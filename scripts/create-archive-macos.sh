#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ezvpn"
PROJECT_NAME="Ezvpn"
SCHEME="Ezvpn"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/create-archive-macos.sh [options]

Builds a macOS .xcarchive, exports a Developer-ID-signed .app, notarizes it with
Apple, staples the ticket, and packages a drag-to-Applications .dmg — the full
pipeline for distributing the app to anyone, outside the Mac App Store.

The tunnel ships as a system extension (target PacketTunnelSysEx), the only
network-extension packaging Apple allows for Developer ID distribution. The app
activates it at first launch via OSSystemExtensionRequest; the user approves it
once in System Settings. System-extension activation only works when the app
runs from /Applications, hence the drag-to-Applications .dmg.

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -c, --configuration NAME    Build configuration. Defaults to Release.
  -m, --method METHOD         Export method. Defaults to developer-id.
                              Use "debugging" for a local development-signed .app
                              (skips notarization + .dmg; runs only on machines
                              registered to your team's provisioning profile).
  -a, --archive-path PATH     Output path for the .xcarchive.
                              Defaults to ./build/${APP_NAME}-macos.xcarchive.
  -o, --export-path PATH      Output directory for the exported .app.
                              Defaults to ./build/export-macos.
  -d, --dmg-path PATH         Output .dmg. Defaults to ./build/${APP_NAME}-<version>.dmg.

Notarization credentials (required for method=developer-id unless --skip-notarize).
Use ONE of:
      --notary-profile NAME   A notarytool keychain profile created once with:
                                xcrun notarytool store-credentials NAME \\
                                  --key <AuthKey_XXXX.p8> --key-id <KEY_ID> \\
                                  --issuer <ISSUER_UUID>
  --- or pass the App Store Connect API key directly: ---
      --key PATH              Path to the AuthKey_XXXX.p8 private key.
      --key-id ID             API key ID (the XXXX in the filename).
      --issuer UUID           API key issuer ID (App Store Connect › Users and
                              Access › Integrations › App Store Connect API).
      --skip-notarize         Sign + export only; skip notarization/stapling/.dmg.

Prerequisites you set up once on Apple's side (this script cannot):
  * A "Developer ID Application" certificate in your login keychain
    (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID
    Application). Without it the export step fails.
  * An App Store Connect API key for notarization (the .p8 above).

Both archive and export run with -allowProvisioningUpdates so Xcode can create
the Developer ID provisioning profile the system extension's network-extension +
keychain entitlements require. This needs an Apple Developer account signed in to
Xcode and network access, and may create/modify signing assets on the portal.

Environment overrides:
  TEAM_ID, CONFIGURATION, METHOD, ARCHIVE_PATH, EXPORT_PATH, DMG_PATH,
  NOTARY_PROFILE, NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
CONFIGURATION="${CONFIGURATION:-Release}"
METHOD="${METHOD:-developer-id}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}-macos.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$PROJECT_ROOT/build/export-macos}"
DMG_PATH="${DMG_PATH:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)        [[ $# -ge 2 ]] || die "$1 requires a value"; TEAM_ID="$2"; shift 2 ;;
    -c|--configuration)  [[ $# -ge 2 ]] || die "$1 requires a value"; CONFIGURATION="$2"; shift 2 ;;
    -m|--method)         [[ $# -ge 2 ]] || die "$1 requires a value"; METHOD="$2"; shift 2 ;;
    -a|--archive-path)   [[ $# -ge 2 ]] || die "$1 requires a value"; ARCHIVE_PATH="$2"; shift 2 ;;
    -o|--export-path)    [[ $# -ge 2 ]] || die "$1 requires a value"; EXPORT_PATH="$2"; shift 2 ;;
    -d|--dmg-path)       [[ $# -ge 2 ]] || die "$1 requires a value"; DMG_PATH="$2"; shift 2 ;;
    --notary-profile)    [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_PROFILE="$2"; shift 2 ;;
    --key)               [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_KEY="$2"; shift 2 ;;
    --key-id)            [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_KEY_ID="$2"; shift 2 ;;
    --issuer)            [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_ISSUER="$2"; shift 2 ;;
    --skip-notarize)     SKIP_NOTARIZE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  usage >&2; die "unknown option: $1" ;;
    *)                   usage >&2; die "unexpected argument: $1" ;;
  esac
done

detect_project_team_id() {
  local xcconfig="$PROJECT_ROOT/Developer.local.xcconfig"
  [[ -f "$xcconfig" ]] || return 1
  /usr/bin/awk '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      sub(/\/\/.*$/, "")
      sub(/.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]"]+$/, ""); gsub(/^[[:space:]"]+/, "")
      if ($0 != "") { print $0; found = 1; exit 0 }
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

# Whether this run notarizes: only Developer-ID builds can be notarized.
NOTARIZE=0
if [[ "$METHOD" == "developer-id" && "$SKIP_NOTARIZE" -eq 0 ]]; then
  NOTARIZE=1
fi

# Resolve notarytool credential args up front so we fail fast, before the long
# archive step, if a developer-id build is missing its credentials.
NOTARY_ARGS=()
if [[ "$NOTARIZE" -eq 1 ]]; then
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
    [[ -f "$NOTARY_KEY" ]] || die "--key file not found: $NOTARY_KEY"
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    usage >&2
    die "notarization needs credentials: pass --notary-profile NAME, or --key/--key-id/--issuer (or --skip-notarize)"
  fi
fi

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

# Clear prior outputs so a mid-flight failure can't leave stale artifacts.
for path in "$ARCHIVE_PATH" "$EXPORT_PATH"; do
  if [[ -e "$path" ]]; then
    echo "Replacing existing: $path"
    /bin/rm -rf "$path"
  fi
done

echo "Creating macOS archive:"
printf '  archive:       %s\n' "$ARCHIVE_PATH"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  method:        %s\n' "$METHOD"
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
cleanup() { /bin/rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :method string $METHOD" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"

echo "Exporting archive:"
printf '  export: %s\n' "$EXPORT_PATH"
printf '  method: %s\n' "$METHOD"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || die "export did not produce $APP_PATH"

if [[ "$NOTARIZE" -eq 0 ]]; then
  echo
  echo "Done: signed .app at $APP_PATH"
  if [[ "$METHOD" != "developer-id" ]]; then
    echo "(method=$METHOD is not a distributable build — no notarization or .dmg.)"
  fi
  exit 0
fi

# Package the .dmg (drag-to-Applications), then notarize + staple the .dmg so
# the whole disk image — and the app inside it — carries a stapled ticket that
# Gatekeeper verifies offline on any Mac.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0")"
[[ -n "$DMG_PATH" ]] || DMG_PATH="$PROJECT_ROOT/build/${APP_NAME}-${VERSION}.dmg"
[[ "$DMG_PATH" == *.dmg ]] || die "--dmg-path must end in .dmg"
[[ -e "$DMG_PATH" ]] && /bin/rm -f "$DMG_PATH"

DMG_STAGE="$TEMP_DIR/dmg"
/bin/mkdir -p "$DMG_STAGE"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGE/${APP_NAME}.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"

echo "Creating disk image:"
printf '  dmg: %s\n' "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

echo "Notarizing (this uploads to Apple and waits for the result)…"
/usr/bin/xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket…"
/usr/bin/xcrun stapler staple "$DMG_PATH"

echo "Verifying Gatekeeper acceptance…"
/usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || \
  echo "warning: spctl assessment reported an issue; inspect the output above."

echo
echo "Done: notarized, stapled disk image at $DMG_PATH"
echo "Distribute this .dmg. Users drag ezvpn to Applications, launch it, and"
echo "approve the network extension once in System Settings."
