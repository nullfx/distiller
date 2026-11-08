import Foundation

/// MCP clients Distiller explains how to connect, in the order the connection guide shows them.
public enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case claudeDesktop = "claude-desktop"
    case claudeCode = "claude-code"
    case chatGPT = "chatgpt"
    case lmStudio = "lm-studio"
    case ollama
    case other

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .other: "Other"
        }
    }

    /// True when the model runs on this Mac, so what the tools return never leaves it.
    public var runsLocally: Bool { self == .lmStudio || self == .ollama }
}

/// How to connect an MCP client to `distiller mcp`: the steps, and configuration snippets with
/// this Mac's real path to the `distiller` command. Shown by the app's connection guide and by
/// `distiller assistant setup`; the website shows the same steps for the default install path.
public struct MCPClientSetup: Sendable {
    /// A piece of configuration or a command to copy.
    public struct Snippet: Equatable, Sendable {
        /// What it is ("claude_desktop_config.json", "Terminal").
        public var label: String
        /// "JSON", "TOML" or "Shell".
        public var language: String
        public var text: String

        public init(label: String, language: String, text: String) {
            self.label = label
            self.language = language
            self.text = text
        }
    }

    public static let serverName = "distiller"
    /// Where the command is in an app installed in /Applications.
    public static let defaultServerPath = "/Applications/Distiller.app/Contents/Helpers/distiller"

    /// The `distiller` command an MCP client starts (inside the app bundle, or the CLI).
    public let serverPath: String

    public init(serverPath: String = MCPClientSetup.defaultServerPath) {
        self.serverPath = serverPath
    }

    /// A first message to send once connected.
    public static let examplePrompt = """
        Use the Distiller tools to work out why my game won't start. List my games, look at its \
        setup and its latest launch log, check the game's own logs and crash dumps, and inspect \
        its program. Then tell me which recipe settings to change (graphics layer, Windows \
        version, winetricks, DLL overrides, environment variables or launch arguments) and why.
        """

    // MARK: Steps

    public func steps(for client: MCPClient) -> [String] {
        switch client {
        case .claudeDesktop:
            [
                "Click Connect, or add the entry below under \"mcpServers\" in ~/Library/Application Support/Claude/claude_desktop_config.json (Claude ▸ Settings ▸ Developer ▸ Edit Config).",
                "Quit and reopen Claude Desktop. Distiller's tools appear under the tools button in a new chat.",
                "Claude asks before each tool call; allow the ones you're happy to share.",
            ]
        case .claudeCode:
            [
                "Run the command below in Terminal. --scope user makes Distiller available in every project.",
                "Start claude and check /mcp lists distiller as connected.",
            ]
        case .chatGPT:
            [
                "In the ChatGPT desktop app, open Settings ▸ MCP servers and add a server: name distiller, type STDIO, command the path below, argument mcp.",
                "The desktop app shares this list with Codex, which keeps it in ~/.codex/config.toml; you can add the entry below there instead.",
                "ChatGPT on the web, and versions of the app that only offer remote (HTTPS) servers, can't use Distiller: its server runs on this Mac and never listens on the network.",
            ]
        case .lmStudio:
            [
                "In LM Studio, open the Program tab in the right-hand sidebar and choose Install ▸ Edit mcp.json.",
                "Add the distiller entry inside \"mcpServers\" and save. LM Studio starts the server and lists its tools.",
                "Load a model that supports tool use (for example a recent Qwen or gpt-oss model) with a context length of at least 32K tokens: logs and recipes are long.",
                "LM Studio asks before each tool call. Everything stays on this Mac.",
            ]
        case .ollama:
            [
                "Ollama runs models but doesn't start MCP servers itself, so pair it with an MCP client that talks to Ollama. One is mcp-client-for-ollama (ollmcp), a terminal chat app: pip install ollmcp.",
                "Save the JSON below as distiller-mcp.json, then start a chat with the command below it.",
                "Use a model that supports tool calling (for example qwen3 or gpt-oss) and give Ollama a larger context: OLLAMA_CONTEXT_LENGTH=32768 ollama serve. Everything stays on this Mac.",
            ]
        case .other:
            [
                "Any MCP client that can start a local (stdio) server can use Distiller: the command is the path below, with the single argument mcp.",
                "Most clients read an \"mcpServers\" block like the one below. The server speaks JSON-RPC over standard input and output, and writes its status to standard error.",
            ]
        }
    }

    // MARK: Snippets

    public func snippets(for client: MCPClient) -> [Snippet] {
        switch client {
        case .claudeDesktop:
            [Snippet(label: "claude_desktop_config.json", language: "JSON", text: mcpServersJSON)]
        case .claudeCode:
            [Snippet(label: "Terminal", language: "Shell", text: "claude mcp add --scope user \(Self.serverName) -- \(Self.shellQuoted(serverPath)) mcp")]
        case .chatGPT:
            [Snippet(label: "~/.codex/config.toml", language: "TOML", text: """
                [mcp_servers.\(Self.serverName)]
                command = \(Self.tomlQuoted(serverPath))
                args = ["mcp"]
                """)]
        case .lmStudio:
            [Snippet(label: "mcp.json", language: "JSON", text: mcpServersJSON)]
        case .ollama:
            [
                Snippet(label: "distiller-mcp.json", language: "JSON", text: mcpServersJSON),
                Snippet(label: "Terminal", language: "Shell", text: "ollmcp --servers-json distiller-mcp.json --model qwen3:14b"),
            ]
        case .other:
            [
                Snippet(label: "mcp.json", language: "JSON", text: mcpServersJSON),
                Snippet(label: "Command", language: "Shell", text: "\(Self.shellQuoted(serverPath)) mcp"),
            ]
        }
    }

    /// The `mcpServers` block most clients read.
    public var mcpServersJSON: String {
        """
        {
          "mcpServers": {
            "\(Self.serverName)": {
              "command": \(Self.jsonQuoted(serverPath)),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    // MARK: Quoting

    static func jsonQuoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A TOML basic string.
    static func tomlQuoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    /// Quoted for a POSIX shell only when it needs to be.
    static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%,")
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
