#!/usr/bin/env bash
#
# Point Packages/Ezvpn/Package.swift's binary target at an ezvpn release and
# keep the app/extension marketing versions in sync with that release.
# Downloads the release's libezvpn-apple.xcframework.zip, computes its SPM
# checksum (the plain sha256 of the zip), rewrites the url + checksum lines, and
# sets both MARKETING_VERSION values in project.yml from the tag.
#
# Usage:
#   scripts/bump-xcframework.sh v0.0.14
#   scripts/bump-xcframework.sh            # defaults to the latest release tag
set -euo pipefail

REPO="andrewtheguy/ezvpn"
ASSET="libezvpn-apple.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../Packages/Ezvpn/Package.swift"
PROJECT_SPEC="$SCRIPT_DIR/../project.yml"

die() { echo "error: $*" >&2; exit 1; }

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  command -v gh >/dev/null || die "no tag given and gh not installed to resolve the latest"
  TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
fi

VERSION="${TAG#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || \
  die "tag '$TAG' does not contain a valid Apple marketing version"

URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -fL --retry 3 -o "$TMP/$ASSET" "$URL" || die "download failed: $URL"
CHECKSUM="$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)"

# BSD sed (macOS) needs the empty -i arg; portable form via a temp file.
sed -E \
  -e "s#url: \"https://github.com/${REPO}/releases/download/[^\"]+\"#url: \"${URL}\"#" \
  -e "s/checksum: \"[a-f0-9]+\"/checksum: \"${CHECKSUM}\"/" \
  "$MANIFEST" > "$TMP/Package.swift"

sed -E \
  -e "s/MARKETING_VERSION: \"[0-9]+(\.[0-9]+){1,2}\"/MARKETING_VERSION: \"${VERSION}\"/g" \
  "$PROJECT_SPEC" > "$TMP/project.yml"

grep -qF "url: \"${URL}\"" "$TMP/Package.swift" || \
  die "failed to rewrite release URL in $MANIFEST"
grep -qF "checksum: \"${CHECKSUM}\"" "$TMP/Package.swift" || \
  die "failed to rewrite checksum in $MANIFEST"
[[ "$(grep -cF "MARKETING_VERSION: \"${VERSION}\"" "$TMP/project.yml")" == "2" ]] || \
  die "expected to update exactly two MARKETING_VERSION settings in $PROJECT_SPEC"

mv "$TMP/Package.swift" "$MANIFEST"
mv "$TMP/project.yml" "$PROJECT_SPEC"

echo "Updated $MANIFEST and $PROJECT_SPEC:"
echo "  tag:      $TAG"
echo "  version:  $VERSION"
echo "  checksum: $CHECKSUM"
