// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI

// MARK: - Sync view

struct SyncView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SyncViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            switch vm.phase {
            case .idle:
                credentialsSection
                syncButton

            case .syncing(let msg):
                Section {
                    HStack {
                        ProgressView()
                        Text(msg).padding(.leading, 8)
                    }
                }
                Button("Cancel", role: .destructive) { vm.abort(backend: appState.backend) }

            case .done(let msg):
                Section(header: Text("Result")) {
                    Text(msg)
                }
                Button("OK") { dismiss() }
                    .buttonStyle(.borderedProminent)

            case .error(let err):
                Section(header: Text("Error")) {
                    Text(err).foregroundStyle(.red)
                }
                Button("Dismiss") { vm.reset() }
            }
        }
        .navigationTitle("Sync")
    }

    private var credentialsSection: some View {
        Group {
            Section(header: Text("AnkiWeb account")) {
                TextField("Username / Email", text: $vm.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $vm.password)
            }
        }
    }

    private var syncButton: some View {
        Button("Sync Now") {
            vm.sync(backend: appState.backend)
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.username.isEmpty || vm.password.isEmpty)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }
}

// MARK: - ViewModel

@MainActor
final class SyncViewModel: ObservableObject {
    enum Phase {
        case idle
        case syncing(String)
        case done(String)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var username: String = ""
    @Published var password: String = ""

    func reset() { phase = .idle }

    func sync(backend: BackendClient?) {
        guard let backend else {
            phase = .error("Backend not initialised")
            return
        }
        Task { await _run(backend: backend) }
    }

    func abort(backend: BackendClient?) {
        guard let backend else { return }
        Task {
            do {
                try backend.run(
                    service: AnkiServiceIndex.SyncService.service,
                    method: AnkiServiceIndex.SyncService.abortSync,
                    request: Anki_Generic_Empty())
            } catch {}
        }
    }

    // MARK: - Private

    private func _run(backend: BackendClient) async {
        do {
            phase = .syncing("Logging in…")
            // 1. Login → get auth token
            let auth: Anki_Sync_SyncAuth = try backend.run(
                service: AnkiServiceIndex.SyncService.service,
                method: AnkiServiceIndex.SyncService.syncLogin,
                request: Anki_Sync_SyncLoginRequest.with {
                    $0.username = username
                    $0.password = password
                })

            // 2. Check status
            phase = .syncing("Checking sync status…")
            let status: Anki_Sync_SyncStatusResponse = try backend.run(
                service: AnkiServiceIndex.SyncService.service,
                method: AnkiServiceIndex.SyncService.syncStatus,
                request: auth)

            switch status.required {
            case .noChanges:
                phase = .done("Collection is already up to date.")
                return

            case .fullSync:
                // Determine direction: if local has no cards → download,
                // if remote has none → upload, otherwise ask the user.
                // For Phase 4 we default to download (safe, non-destructive path).
                phase = .syncing("Full sync required — downloading…")
                try backend.run(
                    service: AnkiServiceIndex.SyncService.service,
                    method: AnkiServiceIndex.SyncService.fullUploadOrDownload,
                    request: Anki_Sync_FullUploadOrDownloadRequest.with {
                        $0.auth = auth
                        $0.upload = false
                    })
                phase = .done("Full sync complete.")
                return

            case .normalSync, .UNRECOGNIZED:
                break
            }

            // 3. Normal sync
            phase = .syncing("Syncing collection…")
            let result: Anki_Sync_SyncCollectionResponse = try backend.run(
                service: AnkiServiceIndex.SyncService.service,
                method: AnkiServiceIndex.SyncService.syncCollection,
                request: Anki_Sync_SyncCollectionRequest.with {
                    $0.auth = auth
                    $0.syncMedia = true
                })

            switch result.required {
            case .noChanges:
                phase = .done("Sync complete. No further changes needed.")
            case .fullSync, .fullDownload, .fullUpload, .normalSync, .UNRECOGNIZED:
                phase = .done("Sync complete (server: \(result.serverMessage)).")
            }

            // 4. Media sync runs async in the backend; just start it.
            // Status can be polled via MediaSyncStatus if needed in Phase 5.

        } catch {
            phase = .error(String(describing: error))
        }
    }
}
