import XCTest
@testable import Veltrio

/// The engine on its own (no window): it starts, loads a stream and feeds
/// the controller. Needs the network.
@MainActor
final class MPVEngineTests: XCTestCase {
    func testLoadsAStreamAndReportsItsDuration() async throws {
        let controller = PlayerController()
        let engine = MPVEngine()
        engine.controller = controller
        controller.view = engine
        engine.start(videoOutput: MPVEngine.headless)
        engine.load(url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
        for _ in 0..<100 where controller.duration <= 0 && controller.playbackError == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNil(controller.playbackError)
        XCTAssertGreaterThan(controller.duration, 500, "the test stream lasts about ten minutes")
        controller.setPaused(true)
        XCTAssertTrue(controller.isPaused)
        engine.shutdown()
    }
}
