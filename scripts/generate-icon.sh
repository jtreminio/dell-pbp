#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/modules build/AppIcon.iconset
xcrun swiftc -module-cache-path "$PWD/build/modules" scripts/generate-icon.swift -framework AppKit -o build/generate-icon
build/generate-icon build/AppIcon.iconset
/usr/bin/iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
