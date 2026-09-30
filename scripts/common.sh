#!/bin/bash
# Sourced by build/release scripts. Never enable shell tracing: signing uses Keychain.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR="$PROJECT_ROOT/build/dependencies/Sparkle-$SPARKLE_VERSION"
# Product defaults come from the app metadata, not the developer's login/account.
# Forks may select a different release repository or Keychain item explicitly.
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)}"
if [[ -z "${RELEASE_REPO:-}" ]]; then
    RELEASE_REPO="$(python3 scripts/release-tools.py default-repository Resources/Info.plist)"
fi
RELEASE_REPO="$(python3 scripts/release-tools.py repository "$RELEASE_REPO")"
UPDATE_FEED_URL="https://github.com/$RELEASE_REPO/releases/latest/download/appcast.xml"
export SPARKLE_ACCOUNT RELEASE_REPO
PUBLIC_KEY_FILE="$PROJECT_ROOT/Resources/SparklePublicKey.txt"
APP_PATH="$PROJECT_ROOT/build/Dell PBP.app"
ARCHIVE_NAME=Dell-PBP-Apple-silicon.zip

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
app_version() {
    local version="${1:-${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}}"
    python3 scripts/release-tools.py version "$version"
}
check_signing_key() {
    [[ -s "$PUBLIC_KEY_FILE" ]] || fail 'Run make setup-signing once before packaging.'
    local public
    public="$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" ||
        fail 'Signing key unavailable in Keychain. Restore the original key; do not generate a replacement.'
    [[ "$public" == "$(cat "$PUBLIC_KEY_FILE")" ]] || fail 'Keychain key does not match Resources/SparklePublicKey.txt.'
}
