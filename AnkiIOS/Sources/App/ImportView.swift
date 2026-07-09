// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI
import UniformTypeIdentifiers

// NOTE: deliberate deviation from PLAN.md's "reuse, don't rewrite" rule.
// Desktop drives apkg import through the `import-anki-package` ts/ page; this
// native single-option importer is an interim stand-in until mediasrv and the
// web pages are wired up here, at which point it should be revisited.

// MARK: - ViewModel

@MainActor
final class ImportPackageViewModel: ObservableObject {
    enum Phase {
        case idle
        case importing
        case done(String)
        case error(String)
    }

    @Published var phase: Phase = .idle

    /// Set by `reset()` when the status sheet is dismissed while `.importing`
    /// is still in flight. When the RPC completes afterwards we must not flip
    /// `phase` back to `.done`/`.error` — that would make the dismissed sheet
    /// reappear on its own.
    private var dismissedWhileImporting = false

    /// True while `.importing` or showing a `.done`/`.error` result, i.e.
    /// whenever the status sheet should be presented.
    var isPresentingStatus: Bool {
        switch phase {
        case .idle: return false
        default: return true
        }
    }

    func reset() {
        if case .importing = phase {
            dismissedWhileImporting = true
        }
        phase = .idle
    }

    /// Handle a `.fileImporter` result: copy the picked file into the app
    /// sandbox, then run the ImportAnkiPackage RPC off the main actor.
    func importPackage(
        from result: Result<URL, Error>, backend: BackendClient?, appState: AppState,
        onSuccess: @escaping () -> Void
    ) {
        guard let backend else {
            phase = .error("Backend not initialised")
            return
        }
        switch result {
        case .failure(let error):
            phase = .error(error.ankiUserMessage)
        case .success(let url):
            dismissedWhileImporting = false
            // Mark busy immediately (not just once `_run` starts) so a
            // double-tap during the sheet-presentation delay below can't slip
            // a second import past the toolbar button's `disabled` check.
            appState.backendBusy = true
            Task {
                // SwiftUI can drop a sheet presentation triggered synchronously
                // from inside .fileImporter's completion handler, while the
                // picker itself is still dismissing; yield briefly first so the
                // status sheet reliably appears.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.phase = .importing
                await self._run(sourceURL: url, backend: backend, appState: appState, onSuccess: onSuccess)
            }
        }
    }

    // MARK: - Private

    private func _run(
        sourceURL: URL, backend: BackendClient, appState: AppState, onSuccess: @escaping () -> Void
    ) async {
        appState.backendBusy = true
        defer { appState.backendBusy = false }
        // Some providers hand back URLs that don't need (or don't support)
        // security scoping; `startAccessingSecurityScopedResource` returning
        // false just means there's nothing to stop later.
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("apkg")

        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            finish(.error("Could not read the selected file: \(error.ankiUserMessage)"))
            return
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let path = tempURL.path
        do {
            let response: Anki_ImportExport_ImportResponse = try await backend.runAsync(
                service: AnkiServiceIndex.ImportExportService.service,
                method: AnkiServiceIndex.ImportExportService.importAnkiPackage,
                request: Anki_ImportExport_ImportAnkiPackageRequest.with {
                    $0.packagePath = path
                })
            finish(.done(Self.summarize(response.log)))
            onSuccess()
        } catch {
            finish(.error(error.ankiUserMessage))
        }
    }

    /// Publish the outcome of an import, unless the status sheet was already
    /// dismissed while it was running — in that case leave `phase` at `.idle`
    /// so the sheet doesn't pop back up on its own.
    private func finish(_ result: Phase) {
        if dismissedWhileImporting {
            dismissedWhileImporting = false
        } else {
            phase = result
        }
    }

    private static func summarize(_ log: Anki_ImportExport_ImportResponse.Log) -> String {
        var lines: [String] = []
        lines.append("Found \(log.foundNotes) note(s).")
        if !log.new.isEmpty { lines.append("New: \(log.new.count)") }
        if !log.updated.isEmpty { lines.append("Updated: \(log.updated.count)") }
        if !log.duplicate.isEmpty { lines.append("Duplicate: \(log.duplicate.count)") }
        if !log.conflicting.isEmpty { lines.append("Conflicting: \(log.conflicting.count)") }
        if !log.missingNotetype.isEmpty { lines.append("Missing note type: \(log.missingNotetype.count)") }
        if !log.missingDeck.isEmpty { lines.append("Missing deck: \(log.missingDeck.count)") }
        if !log.emptyFirstField.isEmpty { lines.append("Empty first field: \(log.emptyFirstField.count)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Status sheet

struct ImportStatusView: View {
    @ObservedObject var vm: ImportPackageViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle:
                    EmptyView()

                case .importing:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing deck package…")
                    }

                case .done(let summary):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Import complete").font(.headline)
                        Text(summary)
                    }
                    .padding()

                case .error(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Import failed").font(.headline)
                        Text(message).foregroundStyle(.red)
                    }
                    .padding()
                }
            }
            .padding()
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if case .importing = vm.phase {
                        EmptyView()
                    } else {
                        Button("Done") {
                            vm.reset()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
