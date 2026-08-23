#!/usr/bin/env bash
# Build Kikiyaku.app: swift build -> assemble the .app bundle -> codesign.
# Signs ad hoc by default. Set KIKIYAKU_CODESIGN_IDENTITY to use a stable identity
# (ad-hoc signing resets TCC permissions on every rebuild).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo ">> swift build -c release"
swift build -c release --arch arm64
BINDIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BINDIR/kikiyaku"

APP="$ROOT/build/Kikiyaku.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/kikiyaku"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundle the SwiftPM resource bundle (localized strings).
# Without it, resolving the resource bundle fails at launch.
RES_BUNDLE="$BINDIR/kikiyaku_kikiyaku.bundle"
if [ -d "$RES_BUNDLE" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# Localizations for the permission dialog texts. InfoPlist.strings must live in
# the main .app bundle's lproj directories, not in the SwiftPM resource bundle.
for lang in ja en; do
    if [ -f "$ROOT/Resources/$lang.lproj/InfoPlist.strings" ]; then
        mkdir -p "$APP/Contents/Resources/$lang.lproj"
        cp "$ROOT/Resources/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
    fi
done

# Unless an identity is given explicitly, use the self-signed development
# certificate "kikiyaku-dev" when present, falling back to ad-hoc signing.
if [ -n "${KIKIYAKU_CODESIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$KIKIYAKU_CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"kikiyaku-dev"'; then
    SIGN_IDENTITY="kikiyaku-dev"
else
    SIGN_IDENTITY="-"
fi
echo ">> codesign (identity: $SIGN_IDENTITY)"
/usr/bin/codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Resources/kikiyaku.entitlements" \
    --options runtime \
    "$APP"

echo ">> built: $APP"
echo ">> run with: open $APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo ">> NOTE: ad-hoc signature; TCC permissions will be requested again after every rebuild."
fi
