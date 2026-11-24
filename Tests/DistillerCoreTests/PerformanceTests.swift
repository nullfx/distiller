import Foundation
import XCTest
@testable import DistillerCore

/// Frame timings from Apple's Metal performance HUD (`MeasuredLaunch`), read as a game writes
/// them, and the summary of a recorded stretch. Lines are shaped like a real game's under Wine.
final class PerformanceTests: XCTestCase {
    let wineLine = "2026-11-24 13:33:43.179 wine[32287:21025373] metal-HUD: 139,742.17,2234.94,40.01,59.40,13.34,67.48,13.34,6.84,26.68,3.73"

    func testReadsAHUDLine() throws {
        let batch = try XCTUnwrap(FrameLog.parse(Substring(wineLine)))
        XCTAssertEqual(batch.pid, 32287)
        XCTAssertEqual(batch.firstFrame, 139)
        XCTAssertEqual(batch.summary.a, 742.17)
        XCTAssertEqual(batch.summary.b, 2234.94)
        XCTAssertEqual(batch.intervals, [40.01, 13.34, 13.34, 26.68])
        XCTAssertEqual(batch.gpuTimes, [59.40, 67.48, 6.84, 3.73])

        // Without the process prefix (the unified log), a trailing comma, and a 0 interval
        // (no frame) are fine.
        let plain = try XCTUnwrap(FrameLog.parse("metal-HUD: 1,3.39,211.30,16.67,2.00,0,0,"))
        XCTAssertNil(plain.pid)
        XCTAssertEqual(plain.intervals, [16.67])

        XCTAssertNil(FrameLog.parse("err:module:load_dll Library not found"))
        XCTAssertNil(FrameLog.parse("[libMTLHud] Metric com.apple.hud-stat.fps already exist"))
        XCTAssertNil(FrameLog.parse("metal-HUD: x,1,2"))
        XCTAssertNil(FrameLog.parse("metal-HUD: 1,2,3,16.6,nan"), "Not numbers")
        XCTAssertNil(FrameLog.parse("metal-HUD: 1,2,3,-4,1"), "Negative")
    }

    func testStreamJoinsLinesSplitAcrossChunks() {
        let collected = Collected()
        let stream = FrameLogStream { collected.add($0) }
        let text = "fixme:ntdll:x\n" + wineLine + "\nother\n" + wineLine.replacingOccurrences(of: "139,", with: "143,") + "\n"
        let data = Data(text.utf8)
        // Arbitrary chunk boundaries, including inside a line.
        var index = 0
        for size in [5, 40, 1, 300, 17, 9999] where index < data.count {
            let end = min(data.count, index + size)
            stream.append(data[index..<end])
            index = end
        }
        XCTAssertEqual(collected.batches.map(\.firstFrame), [139, 143])

        // A runaway line without a newline is dropped, and the stream recovers after it.
        stream.append(Data(repeating: 0x41, count: FrameLogStream.maxLine + 10))
        stream.append(Data(("tail of the long line\n" + wineLine + "\n").utf8))
        XCTAssertEqual(collected.batches.map(\.firstFrame), [139, 143, 139])
    }

    func testSummarisesFrames() throws {
        // 60 s at 60 fps, then 11 s at 30 fps (as the HUD writes them, rounded), and one 500 ms hitch.
        var intervals = [Double](repeating: 16.67, count: 3600)
        intervals += [Double](repeating: 33.34, count: 330)
        intervals.append(500)
        let summary = try XCTUnwrap(PerformanceSummary(intervals: intervals, gpuTimes: [Double](repeating: 5, count: intervals.count)))
        let total = 3600 * 16.67 + 330 * 33.34 + 500
        XCTAssertEqual(summary.frames, 3931)
        XCTAssertEqual(summary.seconds, total / 1000, accuracy: 0.1)
        XCTAssertEqual(summary.fpsAverage, 3931 / (total / 1000), accuracy: 0.1)
        XCTAssertEqual(summary.frameMsMedian, 16.67)
        XCTAssertEqual(summary.frameMsP95, 33.34)
        XCTAssertEqual(summary.gpuMsMedian, 5)
        // Slowest 1% (39 frames): the hitch and 38 at 30 fps.
        XCTAssertEqual(summary.fps1PercentLow, 1000 / ((500 + 38 * 33.34) / 39), accuracy: 0.1)
        // Slowest 0.1% (3 frames).
        XCTAssertEqual(summary.fps01PercentLow, 1000 / ((500 + 2 * 33.34) / 3), accuracy: 0.1)
        XCTAssertEqual(summary.histogram.count, PerformanceSummary.bucketEdgesMs.count + 1)
        XCTAssertEqual(summary.histogram[2], 91.6, accuracy: 0.1, "60 fps frames")
        XCTAssertEqual(summary.histogram[5], 8.4, accuracy: 0.1, "30 fps frames, rounded up to 33.34 ms by the HUD")
        XCTAssertEqual(summary.histogram[7], 0, accuracy: 0.1, "The hitch is under 0.05%")
        XCTAssertEqual(summary.histogram.reduce(0, +), 100, accuracy: 0.3)
        XCTAssertEqual(summary.timelineFPS.count, 2, "A minute, then a 10-second part-minute")
        XCTAssertEqual(summary.timelineFPS[0], 60, accuracy: 0.1)
        XCTAssertNil(PerformanceSummary(intervals: []))
    }

    func testRecordsOnlyBetweenStartAndStopAndPicksTheGame() throws {
        let clock = Clock()
        let recorder = PerformanceRecorder(now: { clock.now })
        let game = { (first: Int) in FrameBatch(pid: 10, firstFrame: first, summary: (0, 0),
                                                 intervals: [Double](repeating: 1000.0 / 60, count: 60), gpuTimes: []) }
        let launcher = FrameBatch(pid: 11, firstFrame: 1, summary: (0, 0), intervals: [1000.0 / 30], gpuTimes: [])

        recorder.add(game(0))                      // before recording: live only
        XCTAssertEqual(recorder.live.fps ?? 0, 60, accuracy: 0.1)
        XCTAssertEqual(recorder.live.pid, 10)
        XCTAssertFalse(recorder.live.isRecording)

        recorder.start()
        for second in 1...5 {
            clock.now += 1
            recorder.add(game(second * 60))
            recorder.add(launcher)
        }
        XCTAssertTrue(recorder.live.isRecording)
        XCTAssertEqual(recorder.live.recordedFrames, 300)
        XCTAssertEqual(recorder.live.recordedSeconds, 5, accuracy: 0.01)
        let summary = try XCTUnwrap(recorder.stop())
        XCTAssertEqual(summary.frames, 300, "The game's process, not the launcher's")
        XCTAssertEqual(summary.fpsAverage, 60, accuracy: 0.1)
        XCTAssertNil(recorder.stop(), "Nothing recorded after stopping")

        clock.now += 10
        XCTAssertNil(recorder.live.fps, "Nothing drawn lately")
    }

    func testSavesRecordsPerGame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try DistillerEngine(paths: DistillerPaths(root: root, storage: StorageSettings()), hardware: Macs.m3Pro)
        let recipe = Recipe(id: "dxvk", game: GameInfo(title: "Game", slug: "game"),
                            stack: StackSpec(runner: RunnerRequirement(family: "winehq"), graphics: .dxvk),
                            launch: LaunchSpec(exe: #"C:\Game\game.exe"#))
        let game = Game(id: "game-1", title: "Game", bottleID: "b", recipe: recipe)
        let summary = try XCTUnwrap(PerformanceSummary(intervals: [Double](repeating: 16.67, count: 600)))
        let settings = PlaySettings(detail: .high, frameLimit: .vsync, renderResolution: "1920x1080", upscaling: .metalfx)
        let first = engine.performanceRecord(for: game, summary: summary, settings: settings,
                                             display: DisplayInfo(refreshHz: 120, window: "3024x1964"),
                                             at: Date(timeIntervalSince1970: 1_800_000_000))
        let second = engine.performanceRecord(for: game, summary: summary, settings: PlaySettings(), display: nil,
                                              at: Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertEqual(first.hardwareKey, Macs.m3Pro.hardwareKey)
        XCTAssertEqual(first.gameSlug, "game")
        XCTAssertNotEqual(first.id, second.id)
        _ = try engine.savePerformanceRecord(first)
        let url = try engine.savePerformanceRecord(second)
        XCTAssertTrue(url.path.hasPrefix(engine.paths.performance.path))
        XCTAssertEqual(engine.performanceRecords(for: "game-1").map(\.id), [second.id, first.id], "Newest first")
        XCTAssertEqual(engine.performanceRecords(for: "game-1").last, first)
        XCTAssertTrue(engine.performanceRecords(for: "other").isEmpty)
        XCTAssertTrue(PlaySettings.isResolution("1920x1080"))
        XCTAssertFalse(PlaySettings.isResolution("1920 x 1080"))
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FrameBatch] = []
    func add(_ batch: FrameBatch) { lock.lock(); stored.append(batch); lock.unlock() }
    var batches: [FrameBatch] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}
