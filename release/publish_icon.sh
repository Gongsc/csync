#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPICON_DIR="$ROOT_DIR/CSync/Assets.xcassets/AppIcon.appiconset"
ICNS_OUT="$ROOT_DIR/CSync/AppIcon.icns"
DIST_DIR="$ROOT_DIR/release/icons"
DIST_OUT="$DIST_DIR/CSync.icns"

if ! command -v iconutil >/dev/null 2>&1; then
  echo "[publish_icon] error: iconutil not found" >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
  echo "[publish_icon] error: shasum not found" >&2
  exit 1
fi

required_icons=(
  "icon_16x16.png"
  "icon_16x16@2x.png"
  "icon_32x32.png"
  "icon_32x32@2x.png"
  "icon_128x128.png"
  "icon_128x128@2x.png"
  "icon_256x256.png"
  "icon_256x256@2x.png"
  "icon_512x512.png"
  "icon_512x512@2x.png"
)

for icon in "${required_icons[@]}"; do
  if [[ ! -f "$APPICON_DIR/$icon" ]]; then
    echo "[publish_icon] error: missing $APPICON_DIR/$icon" >&2
    exit 1
  fi
done

ICONSET_BASE="$(mktemp -d /tmp/CSync.iconset.tmp.XXXXXX)"
ICONSET_TMP="$ICONSET_BASE/CSync.iconset"
mkdir -p "$ICONSET_TMP"
cleanup() {
  rm -rf "$ICONSET_BASE"
}
trap cleanup EXIT

for icon in "${required_icons[@]}"; do
  cp "$APPICON_DIR/$icon" "$ICONSET_TMP/$icon"
done

iconutil -c icns "$ICONSET_TMP" -o "$ICNS_OUT"
mkdir -p "$DIST_DIR"
cp -f "$ICNS_OUT" "$DIST_OUT"

echo "[publish_icon] generated: $ICNS_OUT"
echo "[publish_icon] copied to: $DIST_OUT"

source_sha="$(shasum -a 256 "$ICNS_OUT" | awk '{print $1}')"
dist_sha="$(shasum -a 256 "$DIST_OUT" | awk '{print $1}')"

echo "[publish_icon] source sha256: $source_sha"
echo "[publish_icon] dist   sha256: $dist_sha"

if [[ "$source_sha" != "$dist_sha" ]]; then
  echo "[publish_icon] error: checksum mismatch after copy" >&2
  exit 1
fi

echo "[publish_icon] done"
