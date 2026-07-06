#!/bin/bash
# Build the bridge staticlib for iOS device + simulator and package an
# xcframework. Must be run on macOS with Xcode installed.
#
# Usage: scripts/build-rust.sh [--release]
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: iOS builds require macOS + Xcode" >&2
    exit 1
fi

PROFILE=debug
CARGO_FLAGS=()
if [[ "${1:-}" == "--release" ]]; then
    PROFILE=release
    CARGO_FLAGS+=(--release)
fi

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)
for t in "${TARGETS[@]}"; do
    rustup target add "$t"
    cargo build -p anki-ios-bridge --target "$t" "${CARGO_FLAGS[@]}"
done

OUT=out/AnkiBridge.xcframework
rm -rf "$OUT"
mkdir -p out

xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/$PROFILE/libanki_ios_bridge.a" \
    -headers bridge/include \
    -library "target/aarch64-apple-ios-sim/$PROFILE/libanki_ios_bridge.a" \
    -headers bridge/include \
    -output "$OUT"

echo "built $OUT"
