import XCTest
@testable import Veltrio

final class EpgTests: XCTestCase {
    private let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="tf1.fr"><display-name>TF1</display-name></channel>
      <channel id="arte.fr"><display-name>ARTE</display-name></channel>
      <channel id="other"><display-name>Other</display-name></channel>
      <programme start="20261118190000 +0100" stop="20261118200000 +0100" channel="tf1.fr">
        <title lang="fr">Journal</title><desc>Infos</desc><category>News</category>
      </programme>
      <programme start="20261118200000 +0100" stop="20261118213000 +0100" channel="TF1.fr">
        <title>Film</title>
      </programme>
      <programme start="20261118190000 +0100" stop="20261118200000 +0100" channel="arte.fr"><title>Doc</title></programme>
      <programme start="20261118190000 +0100" stop="20261118200000 +0100" channel="other"><title>Skipped</title></programme>
      <programme start="20261201190000 +0100" stop="20261201200000 +0100" channel="tf1.fr"><title>Too late</title></programme>
    </tv>
    """

    private func parse(wantedIds: Set<String>, wantedNames: [String: String]) -> EpgParser.Result {
        let start = EpgParser.parseDate("20261118180000 +0100")!
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = EpgParser(wantedIds: wantedIds, wantedNames: wantedNames,
                                 range: start...start.addingTimeInterval(24 * 3600))
        parser.delegate = delegate
        XCTAssertTrue(parser.parse())
        return delegate.result
    }

    func testKeepsWantedChannelsWithinTheWindow() {
        let result = parse(wantedIds: ["tf1.fr"], wantedNames: [:])
        XCTAssertEqual(result.programmes.keys.sorted(), ["tf1.fr"])
        let tf1 = result.programmes["tf1.fr"]!
        XCTAssertEqual(tf1.map(\.title), ["Journal", "Film"])
        XCTAssertEqual(tf1[0].description, "Infos")
        XCTAssertEqual(tf1[0].category, "News")
        XCTAssertEqual(tf1[0].end.timeIntervalSince(tf1[0].start), 3600)
    }

    func testMatchesChannelsByDisplayNameWhenTvgIdIsMissing() {
        let result = parse(wantedIds: [], wantedNames: [EpgStore.nameKey("Arte"): "m3u-arte"])
        XCTAssertEqual(result.nameMatches, ["m3u-arte": "arte.fr"])
        XCTAssertEqual(result.programmes["arte.fr"]?.map(\.title), ["Doc"])
    }

    func testDates() {
        XCTAssertEqual(EpgParser.parseDate("20261118190000 +0100"), EpgParser.parseDate("20261118180000 +0000"))
        XCTAssertNotNil(EpgParser.parseDate("20261118190000"))
        XCTAssertNil(EpgParser.parseDate("garbage"))
    }

    func testGuideURLFromM3UHeader() {
        XCTAssertEqual(EpgStore.headerGuideURL(#"#EXTM3U url-tvg="http://e.tv/guide.xml.gz,http://b" tvg-shift=0"#)?.absoluteString,
                       "http://e.tv/guide.xml.gz")
        XCTAssertEqual(EpgStore.headerGuideURL(#"#EXTM3U x-tvg-url="http://e.tv/g.xml""#)?.absoluteString, "http://e.tv/g.xml")
        XCTAssertNil(EpgStore.headerGuideURL("#EXTM3U"))
        XCTAssertNil(EpgStore.headerGuideURL("#EXTINF:-1,Foo"))
    }

    func testGunzip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("g.xml")
        try Data(xml.utf8).write(to: plain)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-k", "-N", plain.path]
        try task.run(); task.waitUntilExit()
        let gz = dir.appendingPathComponent("g.xml.gz")
        XCTAssertTrue(Gzip.isGzipped(gz))
        let out = dir.appendingPathComponent("out.xml")
        try Gzip.decompress(gz, to: out)
        XCTAssertEqual(try Data(contentsOf: out), Data(xml.utf8))
    }
}
