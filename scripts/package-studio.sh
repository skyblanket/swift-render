#!/bin/sh
# Build and assemble "swift-render Studio.app", sign it, and prove it launches.
#
#   scripts/package-studio.sh                 release build, ad-hoc signature, snapshot check
#   SIGN_ID="Developer ID Application: …" scripts/package-studio.sh    distribution signature
#   SKIP_SNAPSHOT=1 / OUT_DIR=out/Studio / CONFIG=debug               knobs
#
# The app icon is rendered by swift-render itself (scene StudioAppIcon, frame t=2.6),
# then iconutil turns it into AppIcon.icns. Notarization steps: docs/studio.md.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIG=${CONFIG:-release}
OUT_DIR=${OUT_DIR:-out/Studio}
APP="$OUT_DIR/swift-render Studio.app"
SIGN_ID=${SIGN_ID:--}
VERSION=$(sed -n 's/^public let swiftRenderVersion = "\(.*\)"/\1/p' Sources/SwiftRenderTool/Tool.swift)
step() { printf '\n==> %s\n' "$*"; }

step "swift build -c $CONFIG (swift-render-studio, swift-render-mcp)"
swift build -c "$CONFIG" --product swift-render-studio
swift build -c "$CONFIG" --product swift-render-mcp
BIN=$(swift build -c "$CONFIG" --show-bin-path)

step "App icon: render StudioAppIcon with swift-render"
# The icon only needs one frame: a debug CLI build is plenty (and usually already built).
swift build --product swift-render
CLI="$(swift build --show-bin-path)/swift-render"
WORK="$OUT_DIR/.work"
rm -rf "$WORK"
mkdir -p "$WORK/AppIcon.iconset"
"$CLI" frame StudioAppIcon --at 2.6 --width 1024 --height 1024 --out "$WORK/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done

step "Assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/swift-render-studio" "$APP/Contents/MacOS/"
# The MCP server ships inside so Claude Code can be pointed at a stable path.
cp "$BIN/swift-render-mcp" "$APP/Contents/MacOS/"
cp Support/Studio/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "codesign ($([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))"
# Inside out: the nested executable first, then the bundle (no --deep).
TS=$([ "$SIGN_ID" = "-" ] && echo "--timestamp=none" || echo "--timestamp")
codesign --force --options runtime $TS --sign "$SIGN_ID" "$APP/Contents/MacOS/swift-render-mcp"
codesign --force --options runtime $TS --entitlements Support/Studio/Studio.entitlements \
         --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" >/dev/null

step "Verify"
plutil -lint "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/swift-render-mcp" </dev/null >/dev/null 2>&1 &
MCP=$!; sleep 1; kill "$MCP" 2>/dev/null || true
if [ "${SKIP_SNAPSHOT:-0}" != "1" ]; then
  # Offscreen launch of the bundled binary against this repo: exits 0 once a frame shows.
  "$APP/Contents/MacOS/swift-render-studio" "$ROOT" --scene TimelineDemo --at 3 \
      --snapshot "$OUT_DIR/app-snapshot.png"
fi
rm -rf "$WORK"
du -sh "$APP"
echo "Built $APP"
