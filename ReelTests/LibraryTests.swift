import XCTest
@testable import Reel

final class PlaybackHistoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReelHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testResumeRulesAndPersistence() {
        let a = FileIdentity(key: "vol:/Movies/A.mkv"), b = FileIdentity(key: "vol:/Movies/B.mkv")
        let url = URL(fileURLWithPath: "/Volumes/SSD/Movies/A.mkv")
        let history = PlaybackHistory(directory: dir)
        history.record(identity: a, url: url, title: "A", position: 12, duration: 6000)
        XCTAssertNil(history.resumePosition(for: a), "under 30 s isn't worth resuming")
        history.record(identity: a, url: url, title: "A", position: 3725, duration: 6000, audioStreamIndex: 2,
                       subtitleTrackID: .some("stream-5"), now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(history.resumePosition(for: a), 3725)
        history.record(identity: b, url: url, title: "B", position: 5900, duration: 6000, now: Date(timeIntervalSince1970: 200))
        XCTAssertNil(history.resumePosition(for: b), "≥ 95% counts as watched")
        XCTAssertTrue(history.entry(for: b)!.finished)

        XCTAssertEqual(history.recentlyPlayed().map(\.title), ["B", "A"])
        XCTAssertEqual(history.continueWatching().map(\.title), ["A"])

        history.saveNow()
        let reloaded = PlaybackHistory(directory: dir)
        XCTAssertEqual(reloaded.resumePosition(for: a), 3725)
        XCTAssertEqual(reloaded.entry(for: a)?.audioStreamIndex, 2)
        XCTAssertEqual(reloaded.entry(for: a)?.subtitleTrackID, "stream-5")

        // Subtitles turned off explicitly are remembered as off.
        reloaded.record(identity: a, url: url, title: "A", position: 3800, duration: 6000, subtitleTrackID: .some(nil))
        XCTAssertEqual(reloaded.entry(for: a)?.subtitlesOff, true)
    }

    func testFileIdentityIsStable() {
        let url = URL(fileURLWithPath: "/tmp/some/../some/file.mkv")
        XCTAssertEqual(FileIdentity(url: url), FileIdentity(url: URL(fileURLWithPath: "/tmp/some/file.mkv")))
    }
}

final class LibraryScannerTests: XCTestCase {
    func testScanFindsAndProbesFixturesThenUsesCache() async throws {
        let folder = TestMedia.directory
        let id = UUID()
        // The fixtures are tiny, so lift the 1 MB "skip samples" limit.
        let items = await LibraryScanner.scan(folder: folder, folderID: id, cached: [:], minimumSize: 0)
        XCTAssertGreaterThanOrEqual(items.count, 20)
        XCTAssertFalse(items.contains { $0.url.pathExtension == "srt" })
        let hdr = try XCTUnwrap(items.first { $0.fileName == "hevc_hdr10_eac3.mkv" })
        XCTAssertEqual(hdr.badges, ["HDR10"])
        XCTAssertEqual(hdr.width, 640)
        XCTAssertEqual(hdr.audioSummary, "E-AC-3 5.1")
        XCTAssertEqual(items.first { $0.fileName == "dv_p81.mkv" }?.badges, ["DV"])
        XCTAssertEqual(items.first { $0.fileName == "h264_srt_ass.mkv" }?.hasSubtitles, true)

        // Second scan: everything comes from the cache (same size + date).
        let counter = Counter()
        let cached = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let again = await LibraryScanner.scan(folder: folder, folderID: id, cached: cached, minimumSize: 0) { _, total in counter.total = total }
        XCTAssertEqual(again.count, items.count)
        XCTAssertEqual(counter.total, 0)
    }

    private final class Counter: @unchecked Sendable { var total = -1 }
}
