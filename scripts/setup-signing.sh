#!/bin/bash
source "$(dirname "$0")/common.sh"
bash scripts/fetch-sparkle.sh
if [[ -s "$PUBLIC_KEY_FILE" ]]; then
    check_signing_key
    printf 'Existing Sparkle signing key matches this app. Ready.\n'
    exit 0
fi
# generate_keys reuses this account's existing key; it does not rotate it.
"$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_ACCOUNT"
public="$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
python3 scripts/release-tools.py public-key "$public"
printf '%s\n' "$public" > "$PUBLIC_KEY_FILE"
printf 'Saved public key in Resources/SparklePublicKey.txt. Private key stays in Keychain.\n'
