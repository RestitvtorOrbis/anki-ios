import SwiftUI

@main
struct AnkiIOSApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environmentObject(appState)
        }
        // Checkpoint the SQLite WAL to the main database file whenever the app
        // moves to the background, matching the desktop behaviour in qt/aqt.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                appState.checkpoint()
            }
        }
    }
}

/// Owns the backend for the app's lifetime. The collection lives in
/// Application Support (backed up by iOS, not user-visible).
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var backend: BackendClient?
    @Published var startupError: String?
    /// URL of the collection.media folder — passed to ReviewerView for media serving.
    private(set) var mediaFolder: URL?

    init() {
        do {
            let langs = Locale.preferredLanguages
            let client = try BackendClient(preferredLangs: langs.isEmpty ? ["en"] : langs)
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Anki", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try client.openCollection(inDirectory: dir)
            backend = client
            mediaFolder = dir.appendingPathComponent("collection.media", isDirectory: true)
            collectionDir = dir
        } catch {
            startupError = String(describing: error)
        }
    }

    /// Called on scenePhase == .background. Triggers an incremental backup if
    /// enough time has passed (rslib decides; it returns false to skip).
    func checkpoint() {
        guard let backend, let collectionDir else { return }
        let backupFolder = collectionDir
            .appendingPathComponent("backups", isDirectory: true)
        // Non-fatal: ignore errors; worst case the WAL is checkpointed on next open.
        try? FileManager.default.createDirectory(
            at: backupFolder, withIntermediateDirectories: true)
        // Void overload: discards the Bool return (true=backed-up, false=skipped).
        do {
            try backend.run(
                service: AnkiServiceIndex.CollectionService.service,
                method: AnkiServiceIndex.CollectionService.createBackup,
                request: Anki_Collection_CreateBackupRequest.with {
                    $0.backupFolder = backupFolder.path
                    $0.force = false
                    $0.waitForCompletion = false
                })
        } catch {
            // Non-fatal; next open will recover from WAL.
        }
    }

    private var collectionDir: URL?
}
