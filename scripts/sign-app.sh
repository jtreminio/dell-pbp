#!/bin/bash
source "$(dirname "$0")/common.sh"
identity="${CODE_SIGN_IDENTITY:--}"
options=(--force --sign "$identity")
if [[ "$identity" != - ]]; then
    options+=(--options runtime --timestamp)
fi
framework="$APP_PATH/Contents/Frameworks/Sparkle.framework"
# Sign from the innermost code outward. No --deep signing or disabled validation.
for code in \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/Updater.app" \
    "$framework/Versions/B/Autoupdate" \
    "$framework" \
    "$APP_PATH/Contents/Helpers/ddc-helper" \
    "$APP_PATH"; do
    codesign "${options[@]}" "$code"
done
codesign --verify --deep --strict "$APP_PATH"
