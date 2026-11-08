import XCTest
@testable import DistillerCore

final class MCPClientSetupTests: XCTestCase {
    /// A path with a space, quotes and a backslash, like an app kept in an oddly named folder.
    let awkwardPath = #"/Volumes/Games "Mac"/It's\Distiller.app/Contents/Helpers/distiller"#

    func testEveryClientHasStepsAndSomethingToCopy() {
        let setup = MCPClientSetup()
        for client in MCPClient.allCases {
            XCTAssertFalse(setup.steps(for: client).isEmpty, client.name)
            XCTAssertFalse(setup.snippets(for: client).isEmpty, client.name)
        }
        XCTAssertEqual(Set(MCPClient.allCases.filter(\.runsLocally)), [.lmStudio, .ollama])
    }

    func testJSONSnippetIsValidAndRunsTheServer() throws {
        let setup = MCPClientSetup(serverPath: awkwardPath)
        let object = try JSONSerialization.jsonObject(with: Data(setup.mcpServersJSON.utf8)) as? [String: Any]
        let entry = (object?["mcpServers"] as? [String: Any])?["distiller"] as? [String: Any]
        XCTAssertEqual(entry?["command"] as? String, awkwardPath)
        XCTAssertEqual(entry?["args"] as? [String], ["mcp"])
        XCTAssertTrue(setup.snippets(for: .lmStudio).contains { $0.text == setup.mcpServersJSON })
    }

    func testDefaultPathNeedsNoQuoting() {
        let setup = MCPClientSetup()
        XCTAssertEqual(setup.snippets(for: .claudeCode).first?.text,
                       "claude mcp add --scope user distiller -- /Applications/Distiller.app/Contents/Helpers/distiller mcp")
        XCTAssertTrue(setup.mcpServersJSON.contains(#""command": "/Applications/Distiller.app/Contents/Helpers/distiller""#))
    }

    func testShellCommandsQuoteThePath() throws {
        let command = try XCTUnwrap(MCPClientSetup(serverPath: awkwardPath).snippets(for: .claudeCode).first?.text)
        XCTAssertEqual(command, #"claude mcp add --scope user distiller -- '/Volumes/Games "Mac"/It'\''s\Distiller.app/Contents/Helpers/distiller' mcp"#)
        // The shell reads the quoted path back as the original.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + MCPClientSetup.shellQuoted(awkwardPath)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), awkwardPath)
    }

    func testTOMLSnippetEscapesThePath() throws {
        let toml = try XCTUnwrap(MCPClientSetup(serverPath: awkwardPath).snippets(for: .chatGPT).first)
        XCTAssertEqual(toml.language, "TOML")
        XCTAssertEqual(toml.text, #"""
            [mcp_servers.distiller]
            command = "/Volumes/Games \"Mac\"/It's\\Distiller.app/Contents/Helpers/distiller"
            args = ["mcp"]
            """#)
    }
}
