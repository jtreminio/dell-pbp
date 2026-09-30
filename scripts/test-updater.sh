#!/bin/bash
source "$(dirname "$0")/common.sh"
[[ -d "$SPARKLE_DIR/Sparkle.framework" ]] || fail 'Run make build once to cache Sparkle before this offline integration test.'
mkdir -p build/modules
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -module-cache-path "$PROJECT_ROOT/build/modules" -F "$SPARKLE_DIR" \
    -framework AppKit -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
    Sources/AppUpdater.swift Tests/AppUpdaterTests.swift -o build/updater-tests
build/updater-tests
