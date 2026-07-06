import SwiftUI

struct DeckListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var decks: [DeckRow] = []
    @State private var error: String?

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
                    NavigationLink(destination: SyncView().environmentObject(appState)) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

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
            self.error = String(describing: error)
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
