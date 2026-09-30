#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build only. Running the resulting program requires an explicit flag.
bash scripts/build.sh
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path "$PWD/build/modules" -import-objc-header Sources/MonitorDDC.h \
  Sources/Models.swift Sources/DisplayWakeGuard.swift Sources/Hardware.swift Tests/HardwareSmoke.swift build/MonitorDDC.o \
  -framework Foundation -framework CoreGraphics -framework CoreDisplay -framework IOKit -o build/hardware-smoke
