// Swift wrapper over the bridge C ABI (bridge/include/anki_bridge.h).
//
// Usage:
//   let backend = try BackendClient(preferredLangs: ["en"])
//   try backend.openCollection(at: url)
//   let tree: Anki_Decks_DeckTreeNode = try backend.run(
//       service: AnkiServiceIndex.DecksService.service,
//       method: AnkiServiceIndex.DecksService.deckTree,
//       request: Anki_Decks_DeckTreeRequest.with { $0.now = now })

import Foundation
import SwiftProtobuf

enum AnkiError: Error {
    case backendInitFailed
    case backendClosed
    // Mirrors anki.backend.BackendError; the full proto is preserved so the
    // UI can localise and inspect kind-specific fields (cf. how
    // pylib/anki/_backend.py maps kinds to exception classes).
    case backend(Anki_Backend_BackendError)
    case invalidResponse
}

extension AnkiError {
    /// A human-readable message suitable for display in the UI.
    ///
    /// Mirrors how pylib/anki/_backend.py surfaces `BackendError.message` to
    /// the user instead of the raw exception repr.
    var userMessage: String {
        switch self {
        case .backend(let err):
            return err.message.isEmpty ? String(describing: err) : err.message
        case .backendInitFailed:
            return "Failed to initialise the Anki backend."
        case .backendClosed:
            return "The Anki backend is not available."
        case .invalidResponse:
            return "Received an invalid response from the backend."
        }
    }
}

extension Error {
    /// A human-readable message for any error, unwrapping `AnkiError` when
    /// possible instead of dumping its raw description.
    var ankiUserMessage: String {
        (self as? AnkiError)?.userMessage ?? String(describing: self)
    }
}

final class BackendClient {
    private var backend: OpaquePointer?

    init(preferredLangs: [String] = ["en"]) throws {
        var initMsg = Anki_Backend_BackendInit()
        initMsg.preferredLangs = preferredLangs
        let bytes = try initMsg.serializedData()
        backend = bytes.withUnsafeBytes { buf in
            anki_open_backend(buf.bindMemory(to: UInt8.self).baseAddress, buf.count)
        }
        guard backend != nil else { throw AnkiError.backendInitFailed }
    }

    deinit {
        close()
    }

    func close() {
        if let backend {
            anki_close_backend(backend)
        }
        backend = nil
    }

    /// Run an RPC with a request and a typed response.
    @discardableResult
    func run<Request: Message, Response: Message>(
        service: UInt32, method: UInt32, request: Request
    ) throws -> Response {
        let responseData = try runRaw(
            service: service, method: method, input: request.serializedData())
        return try Response(serializedBytes: responseData)
    }

    /// Run an RPC whose response is empty.
    func run<Request: Message>(service: UInt32, method: UInt32, request: Request) throws {
        _ = try runRaw(service: service, method: method, input: request.serializedData())
    }

    /// Run an RPC with a request and a typed response, off the main actor.
    ///
    /// The underlying FFI call blocks the calling thread, so this hops onto
    /// a detached task and awaits its result — callers on `@MainActor` won't
    /// block the UI for the duration of the call.
    @discardableResult
    func runAsync<Request: Message, Response: Message>(
        service: UInt32, method: UInt32, request: Request
    ) async throws -> Response {
        try await Task.detached {
            try self.run(service: service, method: method, request: request)
        }.value
    }

    /// Run an RPC whose response is empty, off the main actor.
    ///
    /// The underlying FFI call blocks the calling thread, so this hops onto
    /// a detached task and awaits its result — callers on `@MainActor` won't
    /// block the UI for the duration of the call.
    func runAsync<Request: Message>(service: UInt32, method: UInt32, request: Request) async throws {
        try await Task.detached {
            try self.run(service: service, method: method, request: request)
        }.value
    }

    private func runRaw(service: UInt32, method: UInt32, input: Data) throws -> Data {
        guard let backend else { throw AnkiError.backendClosed }
        var out: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        let rc = input.withUnsafeBytes { buf in
            anki_run_method(
                backend, service, method,
                buf.bindMemory(to: UInt8.self).baseAddress, buf.count,
                &out, &outLen)
        }
        guard let out else { throw AnkiError.invalidResponse }
        defer { anki_free_bytes(out, outLen) }
        let data = Data(bytes: out, count: outLen)
        if rc != 0 {
            throw AnkiError.backend(try Anki_Backend_BackendError(serializedBytes: data))
        }
        return data
    }
}

extension BackendClient {
    /// Open (creating if needed) the collection in the given directory.
    func openCollection(inDirectory dir: URL) throws {
        var req = Anki_Collection_OpenCollectionRequest()
        req.collectionPath = dir.appendingPathComponent("collection.anki2").path
        req.mediaFolderPath = dir.appendingPathComponent("collection.media").path
        req.mediaDbPath = dir.appendingPathComponent("collection.media.db").path
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("collection.media"),
            withIntermediateDirectories: true)
        try run(
            service: AnkiServiceIndex.CollectionService.service,
            method: AnkiServiceIndex.CollectionService.openCollection,
            request: req)
    }
}
