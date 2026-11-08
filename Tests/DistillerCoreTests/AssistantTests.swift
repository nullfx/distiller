import Foundation
import XCTest
@testable import DistillerCore

final class AssistantToolsTests: XCTestCase {
    private var work: URL!
    private var engine: DistillerEngine!
    private var tools: AssistantTools!
    private var folder: URL!
    private var game: Game!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-assistant-\(UUID().uuidString)", isDirectory: true)
        engine = try DistillerEngine(paths: DistillerPaths(root: work.appendingPathComponent("home"), storage: StorageSettings()), hardware: Macs.m3Pro)
        tools = AssistantTools(engine: engine)
        try installFakeWine(into: engine, id: "wine", version: "11")

        folder = work.appendingPathComponent("Game Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try TestPE.make(imports: ["KERNEL32.dll", "d3d11.dll"]).write(to: folder.appendingPathComponent("Game.exe"))
        let crash = (1...5).map { "[1107/0256\($0)0.000:ERROR:gpu_process_host.cc(975)] GPU process exited unexpectedly" }
        try (["starting"] + crash + ["done"]).joined(separator: "\n").write(to: folder.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("logs/crash.dmp"))

        var draft = RecipeDraft(source: .folder(folder), title: "Example")
        draft.launchProgram = "Game.exe"
        let bottle = Bottle(id: "example-1", name: "Example", wine: "wine@11", createdAt: Date())
        let prefix = engine.bottles.prefix(of: bottle)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/Games"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/users/steamuser/AppData/LocalLow/Studio/Game"), withIntermediateDirectories: true)
        try "unity says hi".write(to: prefix.appendingPathComponent("drive_c/users/steamuser/AppData/LocalLow/Studio/Game/Player.log"), atomically: true, encoding: .utf8)
        try engine.bottles.save(bottle)
        game = Game(id: bottle.id, title: "Example", bottleID: bottle.id, recipe: draft.makeRecipe())
        try engine.library.upsert(game)
        try FileManager.default.createSymbolicLink(at: try engine.userFolderLocation(of: game).url, withDestinationURL: folder)
        try "wine: starting\nerr:module:import_dll Library MSVCP140.dll not found\n".write(
            to: engine.paths.logs.appendingPathComponent("example-1-2026-11-07T08-56-00Z.log"), atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:]) -> AssistantToolResult {
        tools.call(name, arguments: arguments)
    }

    func testListAndGetGame() throws {
        let list = call("list_games")
        XCTAssertFalse(list.isError)
        XCTAssertTrue(list.text.contains("\"example-1\""))
        XCTAssertTrue(list.text.contains("\"ready\""))

        let details = call("get_game", ["game_id": "example-1"])
        XCTAssertFalse(details.isError, details.text)
        XCTAssertTrue(details.text.contains("Recipe (YAML):"))
        XCTAssertTrue(details.text.contains("Game.exe"))
        XCTAssertTrue(details.text.contains("Game Folder"), "Shows where the linked folder really is")

        XCTAssertTrue(call("get_game", ["game_id": "nope"]).isError)
        XCTAssertTrue(call("get_game").isError)
        XCTAssertTrue(call("no_such_tool").isError)
    }

    func testReadLaunchLogFiltersAndLists() {
        let log = call("read_launch_log", ["game_id": "example-1", "filter": "err:"])
        XCTAssertFalse(log.isError, log.text)
        XCTAssertTrue(log.text.contains("example-1-2026-11-07T08-56-00Z.log  ← shown"))
        XCTAssertTrue(log.text.contains("MSVCP140.dll not found"))
        XCTAssertFalse(log.text.contains("wine: starting"))
    }

    func testGameLogsAreFoundAndDeduplicated() {
        let list = call("list_game_logs", ["game_id": "example-1"])
        XCTAssertFalse(list.isError, list.text)
        XCTAssertTrue(list.text.contains("debug.log"))
        XCTAssertTrue(list.text.contains("logs/crash.dmp"))
        XCTAssertTrue(list.text.contains("Player.log"), "The bottle's AppData is searched too")

        let read = call("read_game_file", ["game_id": "example-1", "path": "debug.log"])
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("GPU process exited unexpectedly  (×5)"))
        XCTAssertTrue(read.text.contains("[3 lines]"))

        let raw = call("read_game_file", ["game_id": "example-1", "path": "debug.log", "dedupe": false, "tail": 2])
        XCTAssertTrue(raw.text.contains("[7 lines, showing the last 2]"))

        let windowsPath = call("read_game_file", ["game_id": "example-1", "path": "C:\\users\\steamuser\\AppData\\LocalLow\\Studio\\Game\\Player.log"])
        XCTAssertTrue(windowsPath.text.contains("unity says hi"), windowsPath.text)
    }

    func testReadingStaysInsideTheGameAndRefusesBinaries() {
        for path in ["../../etc/passwd", "/etc/passwd", "~/.ssh/id_rsa", "C:\\..\\..\\secret", "D:\\anything"] {
            XCTAssertTrue(call("read_game_file", ["game_id": "example-1", "path": path]).isError, path)
        }
        XCTAssertTrue(call("read_game_file", ["game_id": "example-1", "path": "logs/crash.dmp"]).text.contains("isn't a text file"))
    }

    func testInspectAndEnvironment() {
        let inspection = call("inspect_program", ["game_id": "example-1"])
        XCTAssertFalse(inspection.isError, inspection.text)
        XCTAssertTrue(inspection.text.contains("d3d11.dll"))
        XCTAssertTrue(inspection.text.contains("Direct3D 11"))

        let environment = call("get_environment")
        XCTAssertFalse(environment.isError, environment.text)
        XCTAssertTrue(environment.text.contains("M3-Pro-18gpu-18gb-macos27"))
        XCTAssertTrue(environment.text.contains("Bottles"))
    }

    func testDedupeKeepsOrderAndCounts() {
        XCTAssertEqual(AssistantTools.dedupe(["a 1", "b", "a 22", "c", "a 3"]), ["a 1  (×3)", "b", "c"])
    }
}

final class MCPServerTests: XCTestCase {
    private var server: MCPServer!
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-mcp-\(UUID().uuidString)", isDirectory: true)
        let engine = try DistillerEngine(paths: DistillerPaths(root: work, storage: StorageSettings()), hardware: Macs.m3Pro)
        server = MCPServer(tools: AssistantTools(engine: engine), version: "test")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func send(_ json: String) throws -> [String: Any]? {
        guard let line = server.handle(json) else { return nil }
        XCTAssertFalse(line.contains("\n"), "Each message must be one line")
        return try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    func testHandshakeAndVersionNegotiation() throws {
        let reply = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let unknown = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])

        XCTAssertNil(try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNotNil(try send(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)?["result"])
    }

    func testToolsListAndCall() throws {
        let list = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AssistantTools.definitions.count)
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        }

        let call = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_games","arguments":{}}}"#))
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(((result["content"] as? [[String: Any]])?.first?["text"] as? String), "The library is empty.")

        let failing = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_game","arguments":{}}}"#))
        XCTAssertEqual((failing["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testProtocolErrors() throws {
        XCTAssertEqual(((try send("not json"))?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual(((try send(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#))?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(((try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rm_rf"}}"#))?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNil(server.handle("   "))
    }
}

final class AssistantSwitchTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func reply(_ server: MCPServer, _ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(json)).utf8)) as? [String: Any])
    }

    func testServerOffersNothingWhileTurnedOff() throws {
        let engine = try DistillerEngine(paths: DistillerPaths(root: work, storage: StorageSettings()), hardware: Macs.m3Pro)
        let flag = LockedFlag(true)
        let server = MCPServer(tools: AssistantTools(engine: engine), version: "test") { flag.value }

        flag.value = false
        let list = try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        let call = try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_games","arguments":{}}}"#)
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, MCPServer.disabledMessage)
        let hello = try reply(server, #"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#)
        XCTAssertEqual((hello["result"] as? [String: Any])?["instructions"] as? String, MCPServer.disabledMessage)

        flag.value = true   // takes effect without restarting the server
        let again = try reply(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        XCTAssertEqual(((again["result"] as? [String: Any])?["tools"] as? [Any])?.count, AssistantTools.definitions.count)
    }

    func testSettingSurvivesAStorageMove() async throws {
        let paths = DistillerPaths(root: work.appendingPathComponent("support"), storage: StorageSettings())
        try paths.ensureDirectories()
        XCTAssertFalse(StorageSettings.load(fromSupportFolder: paths.root).isAssistantEnabled, "Off by default")
        try StorageSettings(assistantEnabled: true).save(toSupportFolder: paths.root)
        // `paths` still holds the settings from before the switch was turned on.
        try await DistillerEngine.moveStorage(.bottles, to: work.appendingPathComponent("elsewhere"), paths: paths)
        XCTAssertTrue(StorageSettings.load(fromSupportFolder: paths.root).isAssistantEnabled)
    }
}

/// A thread-safe Bool for `@Sendable` closures in tests.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
