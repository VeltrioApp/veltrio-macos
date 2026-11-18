#!/usr/bin/env bash
#
# Build a distributable Veltrio.dmg: universal (Apple silicon + Intel),
# signed with a Developer ID, notarized and stapled.
#
# Usage:
#   scripts/release-macos.sh
#
# Signing and notarization come from the environment. Without them the
# script still produces an ad-hoc signed DMG, fine for testing on this Mac
# but blocked by Gatekeeper anywhere else.
#
#   VELTRIO_SIGN_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#                          (see `security find-identity -v -p codesigning`)
#   VELTRIO_TEAM_ID        the 10-character team id
#   VELTRIO_NOTARY_PROFILE a notarytool keychain profile, created once with
#                          xcrun notarytool store-credentials veltrio-notary \
#                            --apple-id you@example.com --team-id TEAMID
#   or, in CI, an App Store Connect API key instead of the profile:
#   VELTRIO_NOTARY_KEY_PATH  path to the AuthKey_XXXX.p8 file
#   VELTRIO_NOTARY_KEY_ID    its key id
#   VELTRIO_NOTARY_ISSUER    the issuer id
#
# Updates (Sparkle) are on when both of these are set:
#
#   VELTRIO_APPCAST_URL         where appcast.xml will be served, e.g.
#                               https://example.com/veltrio/appcast.xml
#   VELTRIO_SPARKLE_PUBLIC_KEY  the EdDSA public key printed by Sparkle's
#                               generate_keys (run once; the private key
#                               stays in the login keychain)
#   VELTRIO_SPARKLE_KEY_FILE    (CI) the private key exported with
#                               `generate_keys -x`; otherwise the keychain
#
# The DMG and appcast.xml then go to that URL's folder; the appcast lists
# every DMG in dist/ and must be uploaded alongside them.
#
# Output: dist/Veltrio-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
IDENTITY="${VELTRIO_SIGN_IDENTITY:-}"
TEAM="${VELTRIO_TEAM_ID:-}"
NOTARY="${VELTRIO_NOTARY_PROFILE:-}"
NOTARY_KEY="${VELTRIO_NOTARY_KEY_PATH:-}"
APPCAST_URL="${VELTRIO_APPCAST_URL:-}"
SPARKLE_KEY="${VELTRIO_SPARKLE_PUBLIC_KEY:-}"

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$APP_DIR/project.yml")"
echo "==> Veltrio $VERSION"

echo "==> Rust core (release pinned in core.version)"
"$ROOT/scripts/fetch-core.sh"
if [ "$(lipo -archs "$APP_DIR/Generated/Lib/libveltrio_core.dylib")" != "x86_64 arm64" ]; then
  echo "error: the core in Generated/ must be universal (x86_64 arm64)" >&2
  exit 1
fi

echo "==> Xcode project"
(cd "$APP_DIR" && xcodegen generate --quiet)

echo "==> Building Release (arm64 + x86_64)"
xcodebuild -project "$APP_DIR/Veltrio.xcodeproj" -scheme Veltrio -configuration Release \
  -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="$TEAM" \
  VELTRIO_APPCAST_URL="$APPCAST_URL" VELTRIO_SPARKLE_PUBLIC_KEY="$SPARKLE_KEY" \
  -quiet build

mkdir -p "$DIST"
APP="$DIST/Veltrio.app"
rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/Veltrio.app" "$APP"

echo "==> Checking the bundle is self-contained"
if find "$APP" -type f -perm +111 -print0 | xargs -0 otool -L 2>/dev/null | grep -E '/opt/homebrew|/usr/local/'; then
  echo "error: the app links a library outside the bundle (above)" >&2
  exit 1
fi

ENTITLEMENTS="$APP_DIR/Veltrio/Veltrio.entitlements"
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with $IDENTITY"
  SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
else
  echo "==> No VELTRIO_SIGN_IDENTITY: ad-hoc signing (this Mac only)"
  SIGN=(codesign --force --sign -)
fi
# Inside out: nested helpers (Sparkle's XPC services and Updater.app),
# then frameworks and dylibs, then the app itself. `find -depth` lists
# children before their parents.
find "$APP/Contents/Frameworks" -depth \
  \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" -o -name "*.framework" -o -name "*.dylib" \) \
  -print0 | while IFS= read -r -d '' item; do
    "${SIGN[@]}" "$item"
  done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> Disk image"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Veltrio.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Veltrio-$VERSION.dmg"
hdiutil create -quiet -volname "Veltrio" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "$IDENTITY" ] && { [ -n "$NOTARY" ] || [ -n "$NOTARY_KEY" ]; }; then
  echo "==> Notarizing (a few minutes)"
  if [ -n "$NOTARY_KEY" ]; then
    AUTH=(--key "$NOTARY_KEY" --key-id "$VELTRIO_NOTARY_KEY_ID" --issuer "$VELTRIO_NOTARY_ISSUER")
  else
    AUTH=(--keychain-profile "$NOTARY")
  fi
  xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "==> Skipping notarization (needs VELTRIO_SIGN_IDENTITY and a notary profile or API key)"
fi

if [ -n "$APPCAST_URL" ] && [ -n "$SPARKLE_KEY" ]; then
  echo "==> Sparkle appcast"
  # generate_appcast lists every archive in dist/: keep older DMGs there
  # and they stay in the feed. The loose .app is only a by-product.
  rm -rf "$APP"
  KEY_ARGS=()
  [ -n "${VELTRIO_SPARKLE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$VELTRIO_SPARKLE_KEY_FILE")
  "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" "${KEY_ARGS[@]}" \
    --download-url-prefix "${APPCAST_URL%/*}/" "$DIST"
  echo "    Upload $DIST/appcast.xml and the DMG to ${APPCAST_URL%/*}/"
else
  echo "==> Updates off for this build (set VELTRIO_APPCAST_URL and VELTRIO_SPARKLE_PUBLIC_KEY)"
fi

echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
lipo -archs "$DERIVED/Build/Products/Release/Veltrio.app/Contents/MacOS/Veltrio"
