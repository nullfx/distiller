import XCTest
@testable import DistillerCore

final class LaunchLogTests: XCTestCase {
    var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func makeLog(head: Int, tail: Int) throws -> (LaunchLog, URL) {
        let url = work.appendingPathComponent("\(UUID().uuidString).log")
        return (LaunchLog(handle: try ProcessRunner.openLog(url), headLimit: head, tailLimit: tail), url)
    }

    func testShortOutputIsKeptWhole() throws {
        let (log, url) = try makeLog(head: 100, tail: 20)
        log.append(Data("hello ".utf8))
        log.append(Data("world".utf8))
        log.finish()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world")
    }

    func testLongOutputKeepsTheStartAndTheEnd() throws {
        let (log, url) = try makeLog(head: 10, tail: 5)
        log.append(Data("0123456789".utf8))       // fills the head exactly
        for _ in 0..<100 { log.append(Data("x".utf8)) }
        log.append(Data("THEEND".utf8))
        log.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("0123456789\n[Distiller: "), text)
        XCTAssertTrue(text.contains("of output left out here"), text)
        XCTAssertTrue(text.hasSuffix("HEEND"), "The last 5 bytes: \(text)")
        XCTAssertEqual(text.filter { $0 == "x" }.count, 0, "Everything between was left out")
    }

    func testNothingIsWrittenAfterFinishing() throws {
        let (log, url) = try makeLog(head: 100, tail: 20)
        log.append(Data("before".utf8))
        log.finish()
        log.finish()
        log.append(Data("after".utf8))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before")
    }

    /// A real launch that prints far more than a log keeps: the file stays small.
    func testLaunchedProgramsLogsAreCapped() throws {
        let url = work.appendingPathComponent("noisy.log")
        let finished = expectation(description: "exit")
        let script = "head -c \(LaunchLog.defaultHeadLimit + LaunchLog.defaultTailLimit + 6_000_000) /dev/zero | tr '\\\\0' x; printf DONE"
        _ = try ProcessRunner.launch(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: [:],
                                     currentDirectory: nil, logFile: url) { _ in finished.fulfill() }
        wait(for: [finished], timeout: 60)
        // The tail is written when the program exits; give the pipe a moment to drain.
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            if text.hasSuffix("DONE") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(text.hasSuffix("DONE"), "The end is kept")
        XCTAssertTrue(text.contains("of output left out here"))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, LaunchLog.defaultHeadLimit + LaunchLog.defaultTailLimit + 1_000)
    }
}
