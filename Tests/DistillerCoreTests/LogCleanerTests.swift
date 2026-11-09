import XCTest
@testable import DistillerCore

final class LogCleanerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let mb: Int64 = 1024 * 1024

    func file(_ name: String, daysAgo: Double, mb size: Int64) -> LogCleaner.LogFile {
        LogCleaner.LogFile(url: URL(fileURLWithPath: "/logs/\(name).log"), size: size * mb, modified: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func names(_ files: [LogCleaner.LogFile]) -> [String] {
        files.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    func testRemovesLogsOlderThanTheRetentionPeriod() {
        let files = [file("old", daysAgo: 20, mb: 1), file("week", daysAgo: 7, mb: 1), file("new", daysAgo: 1, mb: 1)]
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 14, limitBytes: 0)), ["old"])
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 0, limitBytes: 0)), [], "0 keeps them")
    }

    func testRemovesTheOldestUntilUnderTheLimit() {
        let files = [file("c", daysAgo: 1, mb: 300), file("a", daysAgo: 3, mb: 400), file("b", daysAgo: 2, mb: 500)]
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 0, limitBytes: 1024 * mb)), ["a"], "1200 MB → 800 MB")
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 0, limitBytes: 200 * mb)), ["a", "b", "c"])
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 0, limitBytes: 0)), [], "0 means no limit")
    }

    func testNeverRemovesALogBeingWritten() {
        let files = [file("playing", daysAgo: 0.01, mb: 2000), file("yesterday", daysAgo: 1, mb: 10)]
        XCTAssertEqual(names(LogCleaner.plan(files, now: now, retentionDays: 0, limitBytes: 100 * mb)), ["yesterday"],
                       "The running game's log stays even over the limit")
        let ancient = LogCleaner.LogFile(url: URL(fileURLWithPath: "/logs/still-open.log"), size: 1, modified: now.addingTimeInterval(-60))
        XCTAssertEqual(LogCleaner.plan([ancient], now: now, retentionDays: 1, limitBytes: 0), [])
    }

    func testCleansAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub.log"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("game-old.log")
        let fresh = folder.appendingPathComponent("game-fresh.log")
        let other = folder.appendingPathComponent("notes.txt")
        for url in [old, fresh, other] { try Data(repeating: 0x41, count: 1000).write(to: url) }
        let longAgo = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: other.path)

        XCTAssertEqual(LogCleaner.usage(of: LogCleaner.files(in: folder)).files, 2, "Only .log files, not folders or other files")
        let result = LogCleaner.clean(folder, retentionDays: 14, limitMB: 1024)
        XCTAssertEqual(result, LogCleaner.Result(removed: 1, freedBytes: 1000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testSettings() throws {
        XCTAssertEqual(StorageSettings().effectiveLogRetentionDays, 14)
        XCTAssertEqual(StorageSettings().effectiveLogLimitMB, 1024)
        var settings = StorageSettings()
        settings.logRetentionDays = 0
        settings.logLimitMB = 250
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertTrue(json.contains("\"log_retention_days\":0") && json.contains("\"log_limit_mb\":250"), json)
        let decoded = try JSONDecoder().decode(StorageSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.effectiveLogRetentionDays, 0)
        XCTAssertEqual(decoded.effectiveLogLimitMB, 250)
    }
}
