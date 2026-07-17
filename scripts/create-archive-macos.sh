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
  -c, --configuration NAME    Build configuration. Defaults to Release for
                              method=developer-id and Debug otherwise: the Release
                              macOS entitlements request the "-systemextension"
                              networkextension value that only Developer ID
                              profiles grant, so a development-signed Release
                              build cannot sign.
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
    Application). Without it the signing step fails.
  * The manually managed Developer ID provisioning profiles "ezvpn Developer ID
    app" and "ezvpn Developer ID sysex" (created once on the portal via the App
    Store Connect API, profileType MAC_APP_DIRECT). project.yml pins them by
    name for Release macOS builds; -allowProvisioningUpdates downloads them
    automatically on a fresh machine.
  * An App Store Connect API key for notarization (the .p8 above).

Release macOS builds sign manually with Developer ID (wired in project.yml):
automatic signing can only archive with a development identity, whose profile
cannot grant the "-systemextension" networkextension value the Release
entitlements request. method=debugging archives + exports with automatic
development signing instead, which needs an Apple Developer account signed in
to Xcode.

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
CONFIGURATION="${CONFIGURATION:-}"
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

# Read a `VAR = value` assignment out of the developer xcconfigs (the local
# override first, then the committed default).
detect_xcconfig_var() {
  local var="$1" xcconfig
  for xcconfig in "$PROJECT_ROOT/Developer.local.xcconfig" "$PROJECT_ROOT/Developer.xcconfig"; do
    [[ -f "$xcconfig" ]] || continue
    /usr/bin/awk -v var="$var" '
      $0 ~ "^[[:space:]]*" var "[[:space:]]*=" {
        sub(/\/\/.*$/, "")
        sub("^[[:space:]]*" var "[[:space:]]*=[[:space:]]*", "")
        gsub(/[[:space:]"]+$/, ""); gsub(/^[[:space:]"]+/, "")
        if ($0 != "") { print $0; found = 1; exit 0 }
      }
      END { if (!found) exit 1 }
    ' "$xcconfig" && return 0
  done
  return 1
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_xcconfig_var DEVELOPMENT_TEAM || true)"
fi
[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig (copy Developer.local.xcconfig.sample) or pass --team-id"
}
if [[ -z "$CONFIGURATION" ]]; then
  # Release entitlements carry the "-systemextension" networkextension value
  # only Developer ID profiles grant, so development-signed methods default to
  # Debug (whose entitlements carry the base value development profiles grant).
  if [[ "$METHOD" == "developer-id" ]]; then CONFIGURATION=Release; else CONFIGURATION=Debug; fi
fi
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

# When an App Store Connect API key is supplied, also hand it to xcodebuild so
# -allowProvisioningUpdates can download the manually-managed Developer ID
# profiles non-interactively. Local runs with an Xcode account signed in don't
# need this (the profiles come from the account), but a fresh CI runner has no
# account, so the key is the only way in. Independent of notarization — the
# archive needs profiles even under --skip-notarize.
PROFILE_AUTH_ARGS=()
if [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
  [[ -f "$NOTARY_KEY" ]] || die "--key file not found: $NOTARY_KEY"
  PROFILE_AUTH_ARGS=(
    -authenticationKeyPath "$NOTARY_KEY"
    -authenticationKeyID "$NOTARY_KEY_ID"
    -authenticationKeyIssuerID "$NOTARY_ISSUER"
  )
fi

# Fail fast, before the long archive step, if the Developer ID certificate is
# missing. The two named provisioning profiles project.yml pins need no check:
# -allowProvisioningUpdates downloads manually managed profiles on demand.
if [[ "$METHOD" == "developer-id" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | \
    /usr/bin/awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
  [[ -n "$SIGN_IDENTITY" ]] || die "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain — create one in Xcode › Settings › Accounts › Manage Certificates"
fi

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

# Guard against a mistyped or externally-pointed output path (these are
# user-overridable via --archive-path/--export-path or the environment): refuse
# to recursively delete an empty path, the filesystem root, the home directory,
# or the project root itself.
assert_safe_to_remove() {
  local path="$1" parent resolved
  parent="$(cd "$(/usr/bin/dirname "$path")" 2>/dev/null && pwd)" \
    || die "refusing to 'rm -rf' $path (parent directory does not resolve)"
  resolved="$parent/$(/usr/bin/basename "$path")"
  case "$resolved" in
    "/"|"$HOME"|"$PROJECT_ROOT")
      die "refusing to 'rm -rf' $path (resolves to $resolved)" ;;
  esac
}

# Clear prior outputs so a mid-flight failure can't leave stale artifacts.
for path in "$ARCHIVE_PATH" "$EXPORT_PATH"; do
  if [[ -e "$path" ]]; then
    assert_safe_to_remove "$path"
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
# the two-platform libezvpn.xcframework (see CLAUDE.md). For developer-id the
# Release build settings in project.yml sign the archive with Developer ID
# directly (manual style + the two named manually managed profiles).
xcodebuild archive \
  -project "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -sdk macosx \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  ${PROFILE_AUTH_ARGS[@]+"${PROFILE_AUTH_ARGS[@]}"} \
  DEVELOPMENT_TEAM="$TEAM_ID"

/bin/mkdir -p "$EXPORT_PATH"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-export.XXXXXX")"
cleanup() { /bin/rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

APP_PATH="$EXPORT_PATH/${APP_NAME}.app"

if [[ "$METHOD" == "developer-id" ]]; then
  # The archive is already fully Developer-ID-signed; just take the app out.
  ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
  [[ -d "$ARCHIVE_APP" ]] || die "archive did not produce $ARCHIVE_APP"
  /usr/bin/ditto "$ARCHIVE_APP" "$APP_PATH"

  echo "Verifying signature…"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH"
else
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

  [[ -d "$APP_PATH" ]] || die "export did not produce $APP_PATH"
fi

if [[ "$NOTARIZE" -eq 0 ]]; then
  echo
  echo "Done: signed .app at $APP_PATH"
  if [[ "$METHOD" != "developer-id" ]]; then
    echo "(method=$METHOD is not a distributable build — no notarization or .dmg.)"
  fi
  exit 0
fi

# Notarize + staple the .app FIRST (sysextd refuses a Developer-ID system
# extension whose app is not notarized — "code signature invalid" — and a
# stapled app validates offline once copied out of the disk image), then
# package the stapled app into the .dmg and notarize + staple that too.
echo "Notarizing the app (this uploads to Apple and waits for the result)…"
APP_ZIP="$TEMP_DIR/${APP_NAME}.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
/usr/bin/xcrun notarytool submit "$APP_ZIP" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket to the app…"
/usr/bin/xcrun stapler staple "$APP_PATH"

# Package the .dmg (drag-to-Applications), then notarize + staple the .dmg so
# the disk image itself also passes Gatekeeper offline.
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

# Sign the disk image itself (not just the app inside) so Gatekeeper's
# primary-signature assessment of the .dmg passes.
/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "Notarizing (this uploads to Apple and waits for the result)…"
/usr/bin/xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket…"
/usr/bin/xcrun stapler staple "$DMG_PATH"

echo "Verifying Gatekeeper acceptance…"
/usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo
echo "Done: notarized, stapled disk image at $DMG_PATH"
echo "Distribute this .dmg. Users drag ezvpn to Applications, launch it, and"
echo "approve the network extension once in System Settings."
