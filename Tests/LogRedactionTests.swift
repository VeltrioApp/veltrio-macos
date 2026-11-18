import XCTest
@testable import Veltrio

final class LogRedactionTests: XCTestCase {
    func testMasksCredentialsInURLs() {
        XCTAssertEqual(DebugLog.redact("Failed to open http://h:8080/movie/bob/p%40ss/123.mkv."),
                       "Failed to open http://h:8080/movie/***/***/123.mkv.")
        XCTAssertEqual(DebugLog.redact("http://j/Videos/1/stream?ApiKey=abc&api_key=abc&Static=true"),
                       "http://j/Videos/1/stream?ApiKey=***&api_key=***&Static=true")
        XCTAssertEqual(DebugLog.redact("player_api.php?username=u&password=secret&action=x"),
                       "player_api.php?username=u&password=***&action=x")
        XCTAssertEqual(DebugLog.redact("plex?X-Plex-Token=zzz"), "plex?X-Plex-Token=***")
    }

    func testLeavesOrdinaryTextAlone() {
        XCTAssertEqual(DebugLog.redact("streams/Torrentio: 12 results"), "streams/Torrentio: 12 results")
    }
}
