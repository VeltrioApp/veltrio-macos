import XCTest
@testable import Veltrio

/// `get_series_info` comes in several shapes depending on the panel.
final class XtreamSeriesInfoTests: XCTestCase {
    private let credentials = XtreamCredentials(host: "prov.tv:8080/", username: "u", password: "p@ss/1", output: "ts")

    private func client(answering json: String) -> XtreamClient {
        StubProtocol.body = Data(json.utf8)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return XtreamClient(session: URLSession(configuration: cfg))
    }

    func testSeasonMapWithMixedIdTypes() async throws {
        let series = try await client(answering: """
        {"info":{"name":"Dark","cover":"http://i/c.jpg","genre":"Drama","releaseDate":"2017-12-01",
                 "rating":"8.7","backdrop_path":["http://i/b.jpg"]},
         "episodes":{"2":[{"id":"902","episode_num":"1","title":"S2 Ep1","container_extension":"mkv","season":2,
                           "info":{"movie_image":"http://i/e.jpg","duration":"00:52:00"}}],
                     "1":[{"id":903,"episode_num":2,"title":"Two","season":"1","info":[]},
                          {"id":"901","episode_num":1,"title":"","season":1}]}}
        """).fetchSeriesInfo(credentials, seriesId: "42")

        XCTAssertEqual(series.name, "Dark")
        XCTAssertEqual(series.rating, "8.7")
        XCTAssertEqual(series.backdrop, "http://i/b.jpg")
        XCTAssertEqual(series.seasons.map(\.number), [1, 2])
        let s1 = series.seasons[0].episodes
        XCTAssertEqual(s1.map(\.number), [1, 2])
        XCTAssertEqual(s1[0].title, "Episode 1", "blank titles fall back to the number")
        // The password is percent-encoded into the path.
        XCTAssertEqual(s1[1].channel.streamUrl, "http://prov.tv:8080/series/u/p%40ss%2F1/903.mp4")
        XCTAssertEqual(series.seasons[1].episodes[0].duration, "00:52:00")
        XCTAssertTrue(s1[0].channel.isOnDemand)
        XCTAssertEqual(StubProtocol.lastURL?.query?.contains("series_id=42"), true)
    }

    func testArrayOfArraysAndStringBackdrop() async throws {
        let series = try await client(answering: """
        {"info":{"name":"X","release_date":"2020","rating":7,"backdrop_path":"http://i/one.jpg"},
         "episodes":[[{"id":"1","episode_num":1,"title":"A"}],[{"id":"2","episode_num":1,"title":"B"}]]}
        """).fetchSeriesInfo(credentials, seriesId: "1")
        XCTAssertEqual(series.releaseDate, "2020")
        XCTAssertEqual(series.rating, "7")
        XCTAssertEqual(series.backdrop, "http://i/one.jpg")
        XCTAssertEqual(series.seasons.map(\.number), [1, 2])
    }

    func testUnknownSeriesIsEmptyNotAnError() async throws {
        let series = try await client(answering: "[]").fetchSeriesInfo(credentials, seriesId: "9")
        XCTAssertTrue(series.seasons.isEmpty)
    }

    func testRejectedCredentials() async {
        do {
            _ = try await client(answering: #"{"user_info":{"auth":0}}"#).fetchSeriesInfo(credentials, seriesId: "9")
            XCTFail("expected an auth error")
        } catch XtreamClient.APIError.authFailed {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: StubProtocol.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
