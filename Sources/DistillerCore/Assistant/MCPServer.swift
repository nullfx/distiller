import Foundation

/// A minimal Model Context Protocol server: JSON-RPC 2.0, one message per line, serving
/// `AssistantTools`. Only what tool use needs is implemented: `initialize`, `ping`,
/// `tools/list` and `tools/call`. The transport (standard input and output) lives in the CLI's
/// `distiller mcp`; this type only turns one incoming line into at most one outgoing line.
public final class MCPServer: @unchecked Sendable {
    /// Protocol revisions this server speaks, newest first. The subset used (tools with text
    /// results) is the same in all of them.
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let tools: AssistantTools
    let version: String
    /// Asked on every request, so turning the assistant off in Settings applies at once.
    let isEnabled: @Sendable () -> Bool

    public static let disabledMessage = "Distiller's troubleshooting assistant is turned off. Turn it on in Distiller ▸ Settings ▸ AI Assistant."

    public init(tools: AssistantTools, version: String, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.tools = tools
        self.version = version
        self.isEnabled = isEnabled
    }

    /// Handles one JSON-RPC message. Returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let message = object as? [String: Any] else {
            return encode(error: -32700, "Parse error: expected one JSON-RPC object per line.", id: NSNull())
        }
        guard let method = message["method"] as? String else {
            return nil   // a response to something we never send; ignore
        }
        guard let id = message["id"], !(id is NSNull) else {
            return nil   // notifications such as notifications/initialized need no reply
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let enabled = isEnabled()
            let requested = params["protocolVersion"] as? String
            let chosen = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return encode(result: [
                "protocolVersion": chosen,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "distiller", "title": "Distiller", "version": version],
                "instructions": enabled ? """
                    Distiller runs Windows games on this Mac with Wine. Use these tools to troubleshoot \
                    a game: start with list_games, then get_game, read_launch_log and list_game_logs / \
                    read_game_file for the game's own logs, inspect_program, and get_environment. \
                    The tools only read. Suggest recipe changes (winetricks verbs, DLL overrides, \
                    environment variables, graphics layer, Windows version, launch arguments) for the \
                    player to apply in Distiller's recipe workshop.
                    """ : Self.disabledMessage,
            ], id: id)

        case "ping":
            return encode(result: [String: Any](), id: id)

        case "tools/list":
            guard isEnabled() else { return encode(result: ["tools": [[String: Any]]()], id: id) }
            let list: [[String: Any]] = AssistantTools.definitions.map { tool in
                [
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": ["title": tool.title, "readOnlyHint": tool.readOnly, "openWorldHint": false],
                ]
            }
            return encode(result: ["tools": list], id: id)

        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(error: -32602, "tools/call needs a tool name.", id: id)
            }
            guard AssistantTools.definitions.contains(where: { $0.name == name }) else {
                return encode(error: -32602, "Unknown tool: \(name)", id: id)
            }
            guard isEnabled() else {
                return encode(result: ["content": [["type": "text", "text": Self.disabledMessage]], "isError": true], id: id)
            }
            let result = tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:])
            return encode(result: [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ], id: id)

        default:
            return encode(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private func encode(result: [String: Any], id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, _ message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func line(_ object: [String: Any]) -> String {
        // No pretty printing: each message must be a single line.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
