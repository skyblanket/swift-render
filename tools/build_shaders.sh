#!/bin/bash
# Rebuild Sources/SwiftRender/Resources/default.metallib from Shaders/*.metal.
# Run this after editing any .metal file, then `swift build` to embed it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADERS="$ROOT/Sources/SwiftRender/Shaders"
OUT="$ROOT/Sources/SwiftRender/Resources/default.metallib"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$SHADERS"/*.metal; do
  xcrun -sdk macosx metal -c "$f" -o "$TMP/$(basename "${f%.metal}").air"
done
xcrun -sdk macosx metallib "$TMP"/*.air -o "$OUT"
echo "rebuilt $OUT — run 'swift build' to embed it"
