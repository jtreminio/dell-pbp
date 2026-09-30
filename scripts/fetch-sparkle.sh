#!/bin/bash
source "$(dirname "$0")/common.sh"
archive="$PROJECT_ROOT/build/dependencies/Sparkle-$SPARKLE_VERSION.tar.xz"
mkdir -p "$(dirname "$archive")"
if [[ ! -f "$archive" ]]; then
    temporary="$(mktemp "${archive}.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$temporary"
    [[ "$(shasum -a 256 "$temporary" | awk '{print $1}')" == "$SPARKLE_SHA256" ]] || fail 'Sparkle download checksum mismatch.'
    mv "$temporary" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$SPARKLE_SHA256" ]] || fail 'Cached Sparkle archive checksum mismatch.'
if [[ ! -f "$SPARKLE_DIR/.verified-$SPARKLE_SHA256" ]]; then
    mkdir -p "$SPARKLE_DIR"
    tar -xf "$archive" -C "$SPARKLE_DIR" ./Sparkle.framework ./bin ./LICENSE
    touch "$SPARKLE_DIR/.verified-$SPARKLE_SHA256"
fi
