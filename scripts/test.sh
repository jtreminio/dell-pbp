#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/modules
SDKROOT_PATH="$(xcrun --show-sdk-path)"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/modules" -Wall -Wextra -Werror \
  -target arm64-apple-macos13.0 -isysroot "$SDKROOT_PATH" -c Sources/MonitorDDC.m -o build/MonitorDDC.o
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDKROOT_PATH" \
  -module-cache-path "$PWD/build/modules" -import-objc-header Sources/MonitorDDC.h \
  Sources/Models.swift Tests/Tests.swift build/MonitorDDC.o \
  -framework Foundation -framework CoreGraphics -framework CoreDisplay -framework IOKit -o build/tests
build/tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_release*.py'
