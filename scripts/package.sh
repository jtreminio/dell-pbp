#!/bin/bash
source "$(dirname "$0")/common.sh"
version="$(app_version "${1:-}")"
export APP_VERSION="$version"
bash scripts/fetch-sparkle.sh
check_signing_key
bash scripts/build.sh
directory="$PROJECT_ROOT/build/releases/v$version"
mkdir -p "$directory"
# Each generation starts with only its own archive: no stale feed entries/deltas.
staging="$(mktemp -d "$PROJECT_ROOT/build/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "${CODE_SIGN_IDENTITY:--}" != - ]] || fail 'Notarization requires CODE_SIGN_IDENTITY.'
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$staging/notarize.zip"
    xcrun notarytool submit "$staging/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    rm "$staging/notarize.zip"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$staging/$ARCHIVE_NAME"
if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    cp "$RELEASE_NOTES_FILE" "$staging/${ARCHIVE_NAME%.zip}.md"
fi
"$SPARKLE_DIR/bin/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$RELEASE_REPO/releases/download/v$version/" \
    --link "https://github.com/$RELEASE_REPO" \
    --full-release-notes-url "https://github.com/$RELEASE_REPO/releases" \
    --maximum-deltas 0 --embed-release-notes "$staging"
signature="$(python3 scripts/release-tools.py feed "$staging" "$version" "$PUBLIC_KEY_FILE" "$RELEASE_REPO")"
"$SPARKLE_DIR/bin/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$staging/$ARCHIVE_NAME" "$signature"
"$SPARKLE_DIR/bin/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$staging/appcast.xml"
(cd "$staging" && shasum -a 256 "$ARCHIVE_NAME" appcast.xml > SHA256SUMS)
for asset in "$ARCHIVE_NAME" appcast.xml SHA256SUMS; do
    cp "$staging/$asset" "$directory/$asset"
done
printf 'Signed and verified release files: %s\n' "$directory"
