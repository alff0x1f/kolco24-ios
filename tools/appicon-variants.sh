#!/usr/bin/env bash
#
# appicon-variants.sh — generate the iOS 18 dark & tinted app-icon variants
# from the existing light AppIcon-1024.png (graphite compass on white +
# red "24" badge). ImageMagick required (brew: `magick`).
#
# DARK variant   (AppIcon-1024-dark.png):
#   - white background  -> transparent (the iOS system gradient shows through)
#   - graphite compass  -> light #E6EAF0 (a dark compass on a dark bg would vanish)
#   - red "24" badge    -> unchanged
#
# TINTED variant (AppIcon-1024-tinted.png):
#   - white background  -> transparent
#   - everything else   -> grayscale (iOS 18 applies the user's tint itself)
#
# Idempotent: re-run any time to regenerate the two PNGs in place.

set -euo pipefail

MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
if ! command -v "$MAGICK" >/dev/null 2>&1; then
  MAGICK="magick"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONSET_DIR="$SCRIPT_DIR/../kolco24/Assets.xcassets/AppIcon.appiconset"

SRC="$ICONSET_DIR/AppIcon-1024.png"
DARK="$ICONSET_DIR/AppIcon-1024-dark.png"
TINTED="$ICONSET_DIR/AppIcon-1024-tinted.png"

# Source palette (verified via `magick … histogram:`):
#   white background #FFFFFF, graphite compass #1B1C20, red badge #C3011C.
GRAPHITE="#1B1C20"
LIGHT="#E6EAF0"

if [[ ! -f "$SRC" ]]; then
  echo "error: source icon not found: $SRC" >&2
  exit 1
fi

echo "generating dark variant -> $DARK"
# 1. near-white background -> transparent (fuzz swallows the anti-alias fringe;
#    the graphite compass is far from white, so it is untouched).
# 2. graphite compass -> light #E6EAF0 (done AFTER the transparency step, since
#    #E6EAF0 is itself near-white and would otherwise be eaten by step 1); the
#    red badge is far from graphite, so a 25% fuzz leaves it unchanged.
"$MAGICK" "$SRC" \
  -fuzz 15% -transparent white \
  -fuzz 25% -fill "$LIGHT" -opaque "$GRAPHITE" \
  -resize 1024x1024 \
  "$DARK"

echo "generating tinted variant -> $TINTED"
# 1. near-white background -> transparent.
# 2. remaining content -> grayscale (alpha preserved); iOS 18 tints it.
"$MAGICK" "$SRC" \
  -fuzz 15% -transparent white \
  -colorspace Gray \
  -resize 1024x1024 \
  "$TINTED"

echo "done:"
"$MAGICK" identify "$DARK" "$TINTED"
