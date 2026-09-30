#!/bin/bash
source "$(dirname "$0")/common.sh"
version="$(app_version)"
bash scripts/fetch-sparkle.sh
[[ -s "$PUBLIC_KEY_FILE" ]] || fail 'Run make setup-signing once before building.'
python3 scripts/release-tools.py public-key "$(cat "$PUBLIC_KEY_FILE")"
mkdir -p build/modules "build/Dell PBP.app/Contents/MacOS" "build/Dell PBP.app/Contents/Resources" "build/Dell PBP.app/Contents/Helpers"
SDKROOT_PATH="$(xcrun --show-sdk-path)"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/modules" -Wall -Wextra -Werror \
  -target arm64-apple-macos13.0 -isysroot "$SDKROOT_PATH" -c Sources/MonitorDDC.m -o build/MonitorDDC.o
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/modules" -Wall -Wextra -Werror \
  -target arm64-apple-macos13.0 -isysroot "$SDKROOT_PATH" Sources/DDCHelper.m build/MonitorDDC.o \
  -framework Foundation -framework CoreGraphics -framework CoreDisplay -framework IOKit \
  -o "build/Dell PBP.app/Contents/Helpers/ddc-helper"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -sdk "$SDKROOT_PATH" \
  -module-cache-path "$PWD/build/modules" -import-objc-header Sources/MonitorDDC.h \
  Sources/Models.swift Sources/DisplayWakeGuard.swift Sources/Hardware.swift Sources/DisplayChangeObserver.swift Sources/AppUpdater.swift Sources/App.swift Sources/Main.swift build/MonitorDDC.o \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework Foundation -framework CoreGraphics -framework CoreDisplay -framework IOKit -framework ServiceManagement -framework SystemConfiguration \
  -o "build/Dell PBP.app/Contents/MacOS/DellPBP"
cp Resources/Info.plist "build/Dell PBP.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $UPDATE_FEED_URL" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(cat "$PUBLIC_KEY_FILE")" "$APP_PATH/Contents/Info.plist"
mkdir -p "$APP_PATH/Contents/Frameworks"
# Remove only the copied dependency so a rebuild cannot retain old nested signatures.
rm -rf "$APP_PATH/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp Resources/AppIcon.icns "build/Dell PBP.app/Contents/Resources/AppIcon.icns"
cp ThirdParty/m1ddc-LICENSE "build/Dell PBP.app/Contents/Resources/m1ddc-LICENSE"
cp "$SPARKLE_DIR/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE"
bash scripts/sign-app.sh
printf 'Built %s/build/Dell PBP.app\n' "$PWD"
