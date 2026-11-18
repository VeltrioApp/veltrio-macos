import XCTest
@testable import Veltrio

final class ChromecastTests: XCTestCase {
    func testCastMessageRoundTrip() {
        let message = CastMessage(source: "sender-0", destination: "receiver-0",
                                  namespace: "urn:x-cast:com.google.cast.tp.connection",
                                  payload: #"{"type":"CONNECT"}"#)
        XCTAssertEqual(CastMessage(decoding: message.encoded()), message)
    }

    func testEncodingMatchesTheProtobufWireFormat() {
        let bytes = [UInt8](CastMessage(source: "s", destination: "d", namespace: "n", payload: "p").encoded())
        // field 1 = 0, field 2 "s", field 3 "d", field 4 "n", field 5 = 0, field 6 "p"
        XCTAssertEqual(bytes, [0x08, 0x00, 0x12, 0x01, 0x73, 0x1A, 0x01, 0x64, 0x22, 0x01, 0x6E,
                               0x28, 0x00, 0x32, 0x01, 0x70])
    }

    func testLongPayloadUsesMultiByteLength() {
        let payload = String(repeating: "x", count: 300)
        let decoded = CastMessage(decoding: CastMessage(source: "a", destination: "b", namespace: "c", payload: payload).encoded())
        XCTAssertEqual(decoded?.payload.count, 300)
    }

    func testRejectsTruncatedData() {
        let data = CastMessage(source: "a", destination: "b", namespace: "c", payload: "hello").encoded()
        XCTAssertNil(CastMessage(decoding: data.prefix(data.count - 2)))
    }

    func testOnlyRemoteHTTPURLsAreCastable() {
        XCTAssertTrue(ChromecastService.canCast(URL(string: "https://cdn.example.com/a.mp4")))
        XCTAssertTrue(ChromecastService.canCast(URL(string: "http://192.168.1.20:8096/Videos/1/stream")))
        XCTAssertFalse(ChromecastService.canCast(URL(string: "http://127.0.0.1:52000/torrents/0/stream/0")))
        XCTAssertFalse(ChromecastService.canCast(URL(string: "http://localhost:1/x")))
        XCTAssertFalse(ChromecastService.canCast(URL(string: "file:///tmp/a.mkv")))
        XCTAssertFalse(ChromecastService.canCast(nil))
    }

    func testContentType() {
        XCTAssertEqual(CastSession.contentType(for: URL(string: "http://h/live.m3u8")!), "application/x-mpegURL")
        XCTAssertEqual(CastSession.contentType(for: URL(string: "http://h/f.mkv")!), "video/x-matroska")
        XCTAssertEqual(CastSession.contentType(for: URL(string: "http://h/movie/u/p/1")!), "video/mp4")
    }
}
