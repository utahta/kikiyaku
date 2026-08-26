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

# The app icon, named to match CFBundleIconFile in Info.plist. Rebuilt from
# the SVG when ImageMagick is around — every size is then rendered from the
# vector rather than resampled from one bitmap, which is the difference
# between a legible 16px icon and a smudge. Without the tool, the committed
# .icns is used as it is.
ICON_SVG="$ROOT/Resources/icon/AppIcon.svg"
ICON_ICNS="$ROOT/Resources/icon/AppIcon.icns"
if [ -f "$ICON_SVG" ] && command -v magick >/dev/null 2>&1; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    render_icon() {  # size, iconset name
        # Substitute on line 1 only: the background rect carries the same
        # numbers, and rewriting those too would shrink it out of the frame.
        sed "1s|width=\"1024\" height=\"1024\"|width=\"$1\" height=\"$1\"|" \
            "$ICON_SVG" > "$ICONSET/../render.svg"
        # -background none is required: without it magick fills the area
        # outside the icon's rounded shape with white, which shows up in the
        # Dock as a white square around the icon.
        magick -background none "$ICONSET/../render.svg" "$ICONSET/$2.png"
    }
    render_icon 16 icon_16x16;      render_icon 32 icon_16x16@2x
    render_icon 32 icon_32x32;      render_icon 64 icon_32x32@2x
    render_icon 128 icon_128x128;   render_icon 256 icon_128x128@2x
    render_icon 256 icon_256x256;   render_icon 512 icon_256x256@2x
    render_icon 512 icon_512x512;   render_icon 1024 icon_512x512@2x
    iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
    rm -rf "$(dirname "$ICONSET")"
fi
if [ -f "$ICON_ICNS" ]; then
    mkdir -p "$APP/Contents/Resources"
    cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi

# macOS 26 puts apps whose icon is only a legacy .icns onto a white plate in
# the Dock, drawn a size smaller than everyone else's. Compiling the same
# images into an Assets.car — which is what CFBundleIconName in Info.plist
# points at — makes the icon native again. Needs Xcode (not just the command
# line tools); without it the .icns above still works, plate and all.
if [ -f "$ICON_ICNS" ] && xcrun --find actool >/dev/null 2>&1; then
    WORK="$(mktemp -d)"
    if iconutil -c iconset "$ICON_ICNS" -o "$WORK/AppIcon.iconset" 2>/dev/null; then
        SET="$WORK/AppIcon.xcassets/AppIcon.appiconset"
        mkdir -p "$SET"
        cp "$WORK/AppIcon.iconset/"*.png "$SET/"
        printf '{"info":{"author":"kikiyaku","version":1}}' > "$WORK/AppIcon.xcassets/Contents.json"
        {
            printf '{\n  "images": ['
            sep=""
            for size in 16 32 128 256 512; do
                printf '%s\n    {"filename":"icon_%sx%s.png","idiom":"mac","scale":"1x","size":"%sx%s"},' \
                    "$sep" "$size" "$size" "$size" "$size"
                printf '\n    {"filename":"icon_%sx%s@2x.png","idiom":"mac","scale":"2x","size":"%sx%s"}' \
                    "$size" "$size" "$size" "$size"
                sep=","
            done
            printf '\n  ],\n  "info": {"author":"kikiyaku","version":1}\n}\n'
        } > "$SET/Contents.json"
        xcrun actool --compile "$APP/Contents/Resources" --platform macosx \
            --minimum-deployment-target 26.0 --app-icon AppIcon \
            --output-partial-info-plist "$WORK/partial.plist" \
            "$WORK/AppIcon.xcassets" >/dev/null 2>&1 \
            && echo ">> icon: compiled Assets.car (native Dock icon)" \
            || echo ">> NOTE: actool failed; the Dock will fall back to the plated .icns icon."
    fi
    rm -rf "$WORK"
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
