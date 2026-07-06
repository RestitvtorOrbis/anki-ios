#!/bin/bash
# Build the desktop repo's web assets (ts/ -> out/) and copy them into the
# app bundle resources. Run whenever the desktop checkout is updated.
#
# NOTE (Phase 3): the exact disk layout the iOS media server expects is
# defined by the (not yet written) axum server in bridge/. Desktop serves
# from qt/aqt/data/web/data via Python (qt/aqt/mediasrv.py); the layout
# below mirrors what that code reads from out/.
set -euo pipefail

cd "$(dirname "$0")/.."

ANKI_REPO=../anki
DEST=AnkiIOS/Resources/web

(cd "$ANKI_REPO" && ./ninja ts:all)

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$ANKI_REPO/out/ts" "$DEST/"
cp -R "$ANKI_REPO/out/qt/_aqt/data/web/data" "$DEST/" 2>/dev/null || true

echo "web assets copied to $DEST"
