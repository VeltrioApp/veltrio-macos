import XCTest
@testable import Veltrio

/// Jellyfin/Emby library browsing against canned server answers.
final class MediaLibraryTests: XCTestCase {
    private func browser(answering json: String) -> MediaBrowserMatcher {
        StubProtocol.body = Data(json.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return MediaBrowserMatcher(serverUrl: "http://jf:8096", userId: "u1",
                                   session: URLSession(configuration: cfg), headers: [:])
    }

    func testSectionsKeepOnlyFilmAndSeriesLibraries() async {
        let sections = await browser(answering: """
        {"Items":[{"Id":"a","Name":"Films","CollectionType":"movies"},
                  {"Id":"b","Name":"Séries","CollectionType":"tvshows"},
                  {"Id":"c","Name":"Musique","CollectionType":"music"},
                  {"Id":"d","Name":"Mélange"}]}
        """).sections()
        XCTAssertEqual(sections.map(\.name), ["Films", "Séries", "Mélange"])
        XCTAssertEqual(sections.map(\.kind), [.movies, .shows, .mixed])
    }

    func testItemsCarryIMDBIdPosterAndTotal() async {
        let section = MediaLibrarySection(id: "a", name: "Films", kind: .movies)
        let page = await browser(answering: """
        {"TotalRecordCount":120,"Items":[
          {"Id":"m1","Name":"Dune","Type":"Movie","ProductionYear":2021,
           "ProviderIds":{"Imdb":"tt1160419","Tmdb":"438631"},"ImageTags":{"Primary":"t1"}},
          {"Id":"s1","Name":"Home videos","Type":"Series"}]}
        """).items(in: section, start: 0, limit: 60)
        XCTAssertEqual(page.total, 120)
        XCTAssertEqual(page.items.map(\.type), ["movie", "series"])
        XCTAssertEqual(page.items[0].imdbId, "tt1160419")
        XCTAssertEqual(page.items[0].posterURL?.absoluteString,
                       "http://jf:8096/Items/m1/Images/Primary?maxWidth=360&tag=t1&quality=90")
        XCTAssertNil(page.items[1].imdbId)
        XCTAssertNil(page.items[1].posterURL)
        let query = StubProtocol.lastURL?.query ?? ""
        XCTAssertTrue(query.contains("ParentId=a") && query.contains("StartIndex=0") && query.contains("Limit=60"))
    }

    func testEpisodes() async {
        let episodes = await browser(answering: """
        {"Items":[{"Id":"e2","Name":"Two","ParentIndexNumber":1,"IndexNumber":2},
                  {"Id":"e1","ParentIndexNumber":1,"IndexNumber":1}]}
        """).episodes(ofSeries: "s1")
        XCTAssertEqual(episodes.map(\.id), ["e2", "e1"])
        XCTAssertEqual(episodes[1].title, "Episode 1")
    }
}
