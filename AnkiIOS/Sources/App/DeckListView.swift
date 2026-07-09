import SwiftUI
import UniformTypeIdentifiers

struct DeckListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var decks: [DeckRow] = []
    @State private var error: String?
    @StateObject private var importVM = ImportPackageViewModel()
    @State private var isPickingFile = false

    var body: some View {
        NavigationStack {
            Group {
                if let error = appState.startupError ?? error {
                    ContentUnavailableView(
                        "Failed to open collection",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error))
                } else {
                    List(decks) { deck in
                        NavigationLink {
                            if let backend = appState.backend,
                               let mediaFolder = appState.mediaFolder {
                                ReviewerView(
                                    backend: backend,
                                    deckId: deck.id,
                                    mediaFolder: mediaFolder)
                                    .navigationTitle(deck.name)
                            }
                        } label: {
                            HStack {
                                Text(deck.name)
                                    .padding(.leading, CGFloat(deck.level - 1) * 16)
                                Spacer()
                                Text("\(deck.newCount)").foregroundStyle(.blue)
                                Text("\(deck.reviewCount)").foregroundStyle(.green)
                            }
                        }
                        .disabled(deck.newCount == 0 && deck.reviewCount == 0)
                    }
                }
            }
            .navigationTitle("Decks")
            .task { reload() }
            .refreshable { reload() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPickingFile = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(appState.backendBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SyncView().environmentObject(appState)) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: Self.importContentTypes
            ) { result in
                importVM.importPackage(from: result, backend: appState.backend, appState: appState) {
                    reload()
                }
            }
            .sheet(isPresented: Binding(
                get: { importVM.isPresentingStatus },
                set: { presented in if !presented { importVM.reset() } }
            )) {
                ImportStatusView(vm: importVM)
            }
        }
    }

    /// `.apkg` isn't a system UTI, so declare it by extension and always
    /// keep `.data` alongside it as a fallback in case that resolution
    /// fails on a given OS/toolchain, so the file is still selectable.
    private static let importContentTypes: [UTType] = {
        var types: [UTType] = []
        if let apkgType = UTType(filenameExtension: "apkg") {
            types.append(apkgType)
        }
        types.append(.data)
        return types
    }()

    private func reload() {
        guard let backend = appState.backend else { return }
        do {
            var req = Anki_Decks_DeckTreeRequest()
            req.now = Int64(Date().timeIntervalSince1970)
            let tree: Anki_Decks_DeckTreeNode = try backend.run(
                service: AnkiServiceIndex.DecksService.service,
                method: AnkiServiceIndex.DecksService.deckTree,
                request: req)
            decks = flatten(tree)
        } catch {
            self.error = error.ankiUserMessage
        }
    }

    private func flatten(_ node: Anki_Decks_DeckTreeNode) -> [DeckRow] {
        var rows: [DeckRow] = []
        // level 0 is the invisible root
        if node.level > 0 {
            rows.append(
                DeckRow(
                    id: node.deckID, name: node.name, level: Int(node.level),
                    newCount: Int(node.newCount), reviewCount: Int(node.reviewCount)))
        }
        for child in node.children {
            rows.append(contentsOf: flatten(child))
        }
        return rows
    }
}

struct DeckRow: Identifiable {
    let id: Int64
    let name: String
    let level: Int
    let newCount: Int
    let reviewCount: Int
}
