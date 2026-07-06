import SwiftUI

@main
struct AnkiIOSApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environmentObject(appState)
        }
    }
}

/// Owns the backend for the app's lifetime. The collection lives in
/// Application Support (backed up by iOS, not user-visible).
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var backend: BackendClient?
    @Published var startupError: String?

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
        } catch {
            startupError = String(describing: error)
        }
    }
}
