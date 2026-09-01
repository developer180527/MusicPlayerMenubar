#!/usr/bin/env bash
#
# Builds a target and packages it as a styled DMG.
#
#   scripts/make-dmg.sh <version> [scheme] [outdir]
#
# Signing identity comes from $SIGN_IDENTITY. Default is ad-hoc ("-"), which is
# what a free Apple account can actually ship: an "Apple Development"
# certificate is valid only on machines provisioned for it, so signing a public
# download with one is worse than not signing at all. Seamless installs need a
# paid "Developer ID Application" certificate plus notarization.
#
# Requires: create-dmg (brew install create-dmg)

set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version> [scheme] [outdir]}"
SCHEME="${2:-MusicPlayerMenubar}"
OUTDIR="${3:-dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/.dmgbuild"
STAGE="$BUILD/stage"
ASSETS="$BUILD/assets"
APP="$BUILD/Build/Products/Release/$SCHEME.app"
DMG="$OUTDIR/$SCHEME-$VERSION-universal.dmg"

rm -rf "$BUILD" "$DMG"
mkdir -p "$STAGE" "$ASSETS" "$OUTDIR"

echo "==> Building $SCHEME (universal)"
xcodebuild -scheme "$SCHEME" \
	-configuration Release \
	-derivedDataPath "$BUILD" \
	-arch arm64 -arch x86_64 \
	ONLY_ACTIVE_ARCH=NO \
	CODE_SIGN_IDENTITY="" \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=NO \
	DEVELOPMENT_TEAM="" \
	build >/dev/null

echo "==> Architectures"
lipo -info "$APP/Contents/MacOS/$SCHEME"

# Sign after building, so the entitlements file is applied exactly as written
# rather than merged with whatever the build settings would have generated.
ENTITLEMENTS="$ROOT/Entitlements/LocalOnly.entitlements"
[ "$SCHEME" = "MusicPlayerMenubarStream" ] && ENTITLEMENTS="$ROOT/Entitlements/Stream.entitlements"

echo "==> Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" \
	--options runtime \
	--entitlements "$ENTITLEMENTS" \
	--timestamp=none \
	"$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Building volume icon"
ICONSET="$ASSETS/volume.iconset"
SRC="$ROOT/MusicPlayerMenubar/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
cp "$SRC/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$SRC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$SRC/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$SRC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$SRC/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$SRC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$SRC/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$SRC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$SRC/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$SRC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ASSETS/volume.icns"

echo "==> Rendering background"
swift "$ROOT/scripts/make-dmg-background.swift" "$ASSETS/bg.png" 1
swift "$ROOT/scripts/make-dmg-background.swift" "$ASSETS/bg@2x.png" 2
# Multi-resolution TIFF keeps the window crisp on Retina.
tiffutil -cathidpicheck "$ASSETS/bg.png" "$ASSETS/bg@2x.png" -out "$ASSETS/bg.tiff" >/dev/null

echo "==> Creating DMG"
cp -R "$APP" "$STAGE/"
create-dmg \
	--volname "$SCHEME" \
	--volicon "$ASSETS/volume.icns" \
	--background "$ASSETS/bg.tiff" \
	--window-pos 200 120 \
	--window-size 660 400 \
	--icon-size 128 \
	--icon "$SCHEME.app" 170 205 \
	--app-drop-link 490 205 \
	--no-internet-enable \
	--hdiutil-quiet \
	"$DMG" \
	"$STAGE" >/dev/null

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
