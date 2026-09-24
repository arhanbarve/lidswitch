#!/bin/bash
# Regenerate ../Resources/AppIcon.icns from icon.svg. Only needed after editing the SVG.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swiftc -O render.swift -o "$TMP/render"
SET=$TMP/AppIcon.iconset; mkdir "$SET"
for s in 16 32 128 256 512; do
    "$TMP/render" icon.svg "$SET/icon_${s}x${s}.png" $s
    "$TMP/render" icon.svg "$SET/icon_${s}x${s}@2x.png" $((s*2))
done
mkdir -p ../Resources
iconutil -c icns "$SET" -o ../Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns"
