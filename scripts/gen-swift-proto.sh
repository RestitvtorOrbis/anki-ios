#!/bin/bash
# Generate Swift protobuf messages and the service/method index enum.
#
# Requires: protoc, protoc-gen-swift (from apple/swift-protobuf), cargo.
# The generated sources are committed (they change rarely).
set -euo pipefail

cd "$(dirname "$0")/.."

ANKI_REPO=../anki
PROTO_DIR="$ANKI_REPO/proto"
OUT_DIR=AnkiIOS/Sources/Backend/Generated

command -v protoc >/dev/null || { echo "error: protoc not found" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || {
    echo "error: protoc-gen-swift not found (brew install swift-protobuf)" >&2
    exit 1
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

protoc \
    --proto_path="$PROTO_DIR" \
    --swift_out="$OUT_DIR" \
    --swift_opt=Visibility=Public \
    "$PROTO_DIR"/anki/*.proto

# Service/method indices: generated from the same descriptor pool rslib's
# build uses, so they cannot desync from the Rust dispatch table.
cargo run -p gen-service-index > "$OUT_DIR/ServiceIndex.swift"

echo "generated Swift sources in $OUT_DIR"
