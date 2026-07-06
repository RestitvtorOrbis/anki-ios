# Anki iOS

An iOS port of [Anki](https://github.com/ankitects/anki), reusing the
desktop's Rust core (`rslib`), protobuf contracts and Svelte web pages.
See `PLAN.md` for the full architecture and phase plan.

Requires a checkout of `ankitects/anki` (branch `main`) as a **sibling
directory** (`../anki`). The desktop repo's ftl translation submodules must
be initialised:

```sh
cd ../anki && git submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
```

## Layout

- `bridge/` — Rust staticlib exposing a minimal C ABI over rslib
  (protobuf bytes in/out; header in `bridge/include/anki_bridge.h`).
- `tools/gen-service-index/` — generates `ServiceIndex.swift` from the same
  proto descriptor pool rslib's build uses, so RPC indices cannot desync.
- `scripts/` — reproducible builds of the xcframework, Swift protos, and
  web assets (heavy artifacts are gitignored, generated code is committed).
- `AnkiIOS/` — SwiftUI shell. Generate the Xcode project with
  `xcodegen generate` (never commit `.xcodeproj`).

## Building

On Linux or macOS (host target — validates the Rust layer):

```sh
cargo test            # opens a backend, creates a collection, runs deck_tree RPC
```

Requires `protoc` on PATH (`apt install protobuf-compiler` /
`brew install protobuf`).

On macOS (everything else):

```sh
scripts/build-rust.sh          # xcframework for device + simulator
scripts/gen-swift-proto.sh     # Swift protobuf messages + ServiceIndex.swift
scripts/build-web-assets.sh    # Svelte pages into AnkiIOS/Resources/web/
cd AnkiIOS && xcodegen generate
```

## Status

- [x] Phase 1 (Rust portion): bridge crate green on host; FFI test opens a
  collection and runs `deck_tree`. iOS-target build (`build-rust.sh`)
  still needs to be validated on macOS.
- [x] Phase 2 (scaffolding): `ServiceIndex.swift` generated and committed;
  `BackendClient.swift` written; XCTest written — needs macOS to compile
  Swift protos (`gen-swift-proto.sh`) and run in the simulator.
- [ ] Phase 3: deck list + reviewer. **Known deviation from PLAN.md**: the
  plan assumed the page-serving media server lives in rslib; in reality
  desktop serves pages from Python (`qt/aqt/mediasrv.py`) — rslib's axum is
  only the sync server. `anki_start_mediasrv` in the bridge is a stub; an
  axum server replicating mediasrv.py's routes must be written in the
  bridge crate (Phase 3).
- [ ] Phase 4: sync.
- [ ] Phase 5: remaining screens.

## Notes

- No changes to the desktop repo have been needed so far. The bridge crate
  enables `tokio/io-util` itself (feature unified in by other members of the
  desktop workspace, but not in ours).
- Anki is AGPL-3.0; this port must remain AGPL and be renamed before any
  App Store release (AnkiMobile is a separate, official, paid app).
