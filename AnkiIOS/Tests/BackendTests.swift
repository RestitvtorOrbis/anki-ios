// Phase 2 success criterion: open backend, create collection, add a note,
// find it via search — running in the iOS simulator.
import XCTest
@testable import AnkiIOS

final class BackendTests: XCTestCase {
    func testOpenCollectionAddNoteAndSearch() throws {
        let backend = try BackendClient(preferredLangs: ["en"])
        defer { backend.close() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try backend.openCollection(inDirectory: dir)

        // Fetch the Basic notetype to build a note.
        var nameReq = Anki_Generic_String()
        nameReq.val = "Basic"
        let ntid: Anki_Notetypes_NotetypeId = try backend.run(
            service: AnkiServiceIndex.NotetypesService.service,
            method: AnkiServiceIndex.NotetypesService.getNotetypeIdByName,
            request: nameReq)

        var newNoteReq = Anki_Notetypes_NotetypeId()
        newNoteReq.ntid = ntid.ntid
        var note: Anki_Notes_Note = try backend.run(
            service: AnkiServiceIndex.NotesService.service,
            method: AnkiServiceIndex.NotesService.newNote,
            request: newNoteReq)
        note.fields[0] = "front side"
        note.fields[1] = "back side"

        var addReq = Anki_Notes_AddNoteRequest()
        addReq.note = note
        addReq.deckID = 1
        let _: Anki_Collection_OpChangesWithId = try backend.run(
            service: AnkiServiceIndex.NotesService.service,
            method: AnkiServiceIndex.NotesService.addNote,
            request: addReq)

        var searchReq = Anki_Search_SearchRequest()
        searchReq.search = "front"
        let results: Anki_Search_SearchResponse = try backend.run(
            service: AnkiServiceIndex.SearchService.service,
            method: AnkiServiceIndex.SearchService.searchNotes,
            request: searchReq)
        XCTAssertEqual(results.ids.count, 1)
    }
}
