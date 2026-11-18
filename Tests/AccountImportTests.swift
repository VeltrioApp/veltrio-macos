import XCTest
@testable import Veltrio

@MainActor
final class AccountImportTests: XCTestCase {
    private func store() -> WatchStore {
        WatchStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
    }

    func testMergeIsAdditive() {
        let watch = store()
        watch.toggleLibrary(type: "movie", id: "tt1", name: "Dune", poster: "p", background: nil, addonId: nil, addonName: nil)
        watch.reportProgress(type: "movie", id: "tt1", name: "Dune", position: 3000, duration: 9000)

        let changed = watch.merge([
            // Not saved on the account, earlier position: must not undo local state.
            ImportedWatchItem(type: "movie", id: "tt1", name: "Dune", inLibrary: false, watched: false,
                              position: 100, duration: 9000),
            ImportedWatchItem(type: "series", id: "tt2", name: "Dark", inLibrary: true),
        ])
        XCTAssertEqual(changed, 1)
        let dune = watch.entry(type: "movie", id: "tt1")!
        XCTAssertTrue(dune.inLibrary)
        XCTAssertEqual(dune.position, 3000)
        XCTAssertTrue(watch.entry(type: "series", id: "tt2")!.inLibrary)
        XCTAssertEqual(watch.merge([ImportedWatchItem(type: "series", id: "tt2", name: "Dark", inLibrary: true)]), 0,
                       "importing the same thing twice changes nothing")
    }

    func testMergeTakesFurtherProgressAndWatchedFlag() {
        let watch = store()
        watch.merge([ImportedWatchItem(type: "movie", id: "tt3", name: "X", watched: true, position: 5000, duration: 6000)])
        let x = watch.entry(type: "movie", id: "tt3")!
        XCTAssertTrue(x.watched)
        XCTAssertEqual(x.position, 5000)
    }

    func testStremioLibraryItemMapping() throws {
        let json = """
        [{"_id":"tt1160419","name":"Dune","type":"movie","poster":"p","removed":false,"temp":false,
          "state":{"timeOffset":1800000,"duration":9360000,"lastWatched":"2026-11-01T20:15:00.000Z","timesWatched":0,"flaggedWatched":0}},
         {"_id":"tt5753856","name":"Dark","type":"series","removed":false,"temp":true,"state":{"timesWatched":3}},
         {"_id":"kitsu:1","name":"Anime","type":"series"},
         {"_id":"tt1","name":"Gone","type":"movie","removed":true,"state":{"flaggedWatched":1}}]
        """
        let items = try JSONDecoder().decode([StremioAccountService.LibraryItem].self, from: Data(json.utf8))
            .compactMap(StremioAccountService.imported)
        XCTAssertEqual(items.map(\.id), ["tt1160419", "tt5753856", "tt1"])
        XCTAssertEqual(items[0].position, 1800)
        XCTAssertEqual(items[0].duration, 9360)
        XCTAssertTrue(items[0].inLibrary)
        XCTAssertNotNil(items[0].lastWatched)
        XCTAssertFalse(items[1].inLibrary, "temp items aren't saved titles")
        XCTAssertFalse(items[1].watched, "series aren't flagged watched as a whole")
        XCTAssertFalse(items[2].inLibrary)
        XCTAssertTrue(items[2].watched)
    }
}
