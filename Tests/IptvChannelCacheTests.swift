import XCTest
@testable import Veltrio

/// The on-disk channel list: it round-trips, and an Xtream password never
/// lands in it (stream URLs carry it in their path).
final class IptvChannelCacheTests: XCTestCase {
    private let ref = IptvPlaylistRef(
        id: UUID(), name: "Test", url: "",
        xtream: XtreamCredentials(host: "http://provider.test:8080", username: "alice", password: "s3cret", output: "ts"),
        addedAt: Date())

    override func tearDown() {
        IptvChannelCache.remove(playlistId: ref.id)
    }

    func testRoundTripWithoutThePassword() async throws {
        let channel = IptvChannel(id: "x1", name: "France 2", streamUrl: "http://provider.test:8080/live/alice/s3cret/42.ts",
                                  logoUrl: nil, group: "FR", tvgId: "france2.fr", tvgName: nil, tvgCountry: nil, tvgLanguage: nil)
        await IptvChannelCache.save([channel], for: ref, section: "live").value

        let onDisk = try String(contentsOf: IptvChannelCache.file(for: ref.id, section: "live"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("s3cret"))

        let loaded = await IptvChannelCache.load(ref, section: "live")
        XCTAssertEqual(loaded?.channels.first?.streamUrl, channel.streamUrl)
        XCTAssertEqual(loaded?.channels.first?.tvgId, "france2.fr")
        XCTAssertEqual(loaded?.isFresh, true)
        let otherSection = await IptvChannelCache.load(ref, section: "movies")
        XCTAssertNil(otherSection)
    }
}
