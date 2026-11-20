import XCTest
@testable import Veltrio

final class StreamResolutionTests: XCTestCase {
    func testReadsTheAnnouncedResolution() {
        XCTAssertEqual(StreamResolution.of("TORRENTIO 4K NIGHT.OF.THE.LIVING.DEAD.1968.2160P.BLURAY"), "4K")
        XCTAssertEqual(StreamResolution.of("TORRENTIO 1080P NIGHT OF THE LIVING DEAD 1968 1080P BLURAY"), "1080P")
        XCTAssertEqual(StreamResolution.of("[UHD] DUNE"), "4K")
        XCTAssertNil(StreamResolution.of("TORRENTIO SOME FILE"))
    }

    func testSiteNamesDontCountAsResolutions() {
        // Torrentio names the site a release came from; "Wolfmax4k" isn't a 4K tag.
        XCTAssertEqual(StreamResolution.of("TORRENTIO 1080P LA NOCHE [BLURAY 1080P] 💾 1.05 GB ⚙️ WOLFMAX4K"), "1080P")
        XCTAssertNil(StreamResolution.of("RIP BY GROUP4K2160PX"))
    }
}
