import XCTest
@testable import Veltrio

/// Provider names are messy; these pin down how they're matched to an
/// IMDB title and which language tag they get.
final class XtreamMatchingTests: XCTestCase {
    func testMatchesThroughProviderDecoration() {
        XCTAssertTrue(XtreamClient.isSameTitle("NF - The Irishman (2019)", "The Irishman", year: 2019))
        XCTAssertTrue(XtreamClient.isSameTitle("FR | Dune [MULTI]", "Dune", year: 2021))
        XCTAssertTrue(XtreamClient.isSameTitle("NF - TRON: Ares (Multi-Audio)", "TRON: Ares", year: 2025))
        XCTAssertTrue(XtreamClient.isSameTitle("VOSTFR | Léon (1994)", "Leon", year: 1994))
        XCTAssertTrue(XtreamClient.isSameTitle("Fast & Furious 7", "Fast and Furious 7", year: nil))
    }

    func testKeepsTitleWords() {
        XCTAssertTrue(XtreamClient.isSameTitle("Spider-Man: No Way Home (2021)", "Spider-Man: No Way Home", year: 2021))
        XCTAssertTrue(XtreamClient.isSameTitle("ALIEN: Romulus (2024)", "Alien: Romulus", year: 2024))
        XCTAssertFalse(XtreamClient.isSameTitle("Dune: Part Two (2024)", "Dune", year: 2021))
    }

    func testYears() {
        XCTAssertFalse(XtreamClient.isSameTitle("The Founder (2010)", "The Founder", year: 2016))
        XCTAssertTrue(XtreamClient.isSameTitle("Dune 2021", "Dune", year: 2021))
        XCTAssertFalse(XtreamClient.isSameTitle("Dune 2021", "Dune", year: 1984))
        // A number that's part of the title isn't a year.
        XCTAssertTrue(XtreamClient.isSameTitle("Blade Runner 2049", "Blade Runner 2049", year: 2017))
        XCTAssertFalse(XtreamClient.isSameTitle("Blade Runner (1982)", "Blade Runner 2049", year: 2017))
        XCTAssertTrue(XtreamClient.isSameTitle("1917 (2019)", "1917", year: 2019))
    }

    func testLanguageFromCategoryThenLeadingTag() {
        XCTAssertEqual(XtreamClient.language(category: "FR | Films", name: "Dune"), "FR")
        XCTAssertEqual(XtreamClient.language(category: "VOSTFR - Séries", name: nil), "VOSTFR")
        XCTAssertEqual(XtreamClient.language(category: "Netflix", name: "EN - Dune"), "EN")
        XCTAssertEqual(XtreamClient.language(category: "|AR| Aflam", name: nil), "AR")
        XCTAssertEqual(XtreamClient.language(category: "MULTI 4K", name: nil), "MULTI")
    }

    func testTitleWordsAreNotLanguages() {
        XCTAssertNil(XtreamClient.language(category: "Action", name: "It (2017)"))
        XCTAssertNil(XtreamClient.language(category: "Stephen King", name: "Us (2019)"))
        XCTAssertNil(XtreamClient.language(category: "Films 4K", name: "NF - The Irishman"))
    }

    func testSearchFilterNeedsEveryWord() {
        XCTAssertTrue(XtreamClient.title("NF - Mocro Maffia: Taxi", matches: "mocro taxi"))
        XCTAssertFalse(XtreamClient.title("NF - The Irishman (2019)", matches: "mocro"))
        XCTAssertTrue(XtreamClient.title("Léon", matches: "leon"))
    }
}
