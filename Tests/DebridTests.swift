import XCTest
@testable import Veltrio

final class DebridTests: XCTestCase {
    private struct F { let path: String; let size: Int64 }

    func testPicksTheEpisodeInASeasonPack() {
        let files = [F(path: "Show.S01E01.mkv", size: 900), F(path: "Show.S01E02.mkv", size: 800),
                     F(path: "Show.S01E03.mkv", size: 950), F(path: "Show.nfo", size: 2)]
        let pick = DebridFilePicker.pick(files, path: \.path, size: \.size, season: 1, episode: 2)
        XCTAssertEqual(pick?.path, "Show.S01E02.mkv")
    }

    func testPicksTheBiggestVideoOtherwise() {
        let files = [F(path: "Sample.mkv", size: 50), F(path: "Movie.2021.mkv", size: 4000), F(path: "Movie.srt", size: 90_000)]
        XCTAssertEqual(DebridFilePicker.pick(files, path: \.path, size: \.size, season: nil, episode: nil)?.path,
                       "Movie.2021.mkv")
    }

    private func session(answering json: String) -> URLSession {
        StubProtocol.body = Data(json.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testTorBoxCacheCheck() async throws {
        let client = TorBoxClient(session: session(answering: """
        {"success":true,"detail":"ok","data":{"AAAA":{"name":"Dune"}}}
        """))
        let result = try await client.checkCached(hashes: ["aaaa", "bbbb"], apiKey: "k")
        XCTAssertEqual(result, ["aaaa": true, "bbbb": false])
        XCTAssertEqual(StubProtocol.lastURL?.path, "/v1/api/torrents/checkcached")
    }

    func testTorBoxRejectedKey() async {
        let client = TorBoxClient(session: session(answering: #"{"success":false,"detail":"Invalid API key","data":null}"#))
        do {
            _ = try await client.user(apiKey: "bad")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid API key")
        }
    }

    func testPremiumizeCacheCheck() async throws {
        let client = PremiumizeClient(session: session(answering: """
        {"status":"success","response":[true,false],"transcoded":[false,false]}
        """))
        let result = try await client.checkCached(hashes: ["aaaa", "bbbb"], apiKey: "k")
        XCTAssertEqual(result, ["aaaa": true, "bbbb": false])
        XCTAssertEqual(StubProtocol.lastURL?.query?.components(separatedBy: "items%5B%5D=").count, 3)
    }

    func testPremiumizeRejectedKey() async {
        let client = PremiumizeClient(session: session(answering: #"{"status":"error","message":"Not logged in."}"#))
        do {
            _ = try await client.account(apiKey: "bad")
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not logged in.")
        }
    }
}
