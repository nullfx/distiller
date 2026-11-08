import Foundation

/// Adds or removes Distiller's MCP server in Claude Desktop's configuration
/// (`~/Library/Application Support/Claude/claude_desktop_config.json`). Only the
/// `mcpServers.distiller` entry is touched; everything else in the file is kept, and the file
/// is backed up once (`.before-distiller.bak`) before Distiller first changes it.
public struct ClaudeDesktopConfig: Sendable {
    public static let serverName = "distiller"
    public let file: URL

    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// True when Claude Desktop is installed or has been set up (its config folder exists).
    public var claudeDesktopPresent: Bool {
        FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
    }

    /// The command Claude Desktop runs for Distiller, if it's configured.
    public func configuredCommand() -> String? {
        guard let config = try? read(), let servers = config["mcpServers"] as? [String: Any],
              let entry = servers[Self.serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// Points Claude Desktop at `distiller` (the CLI that serves `distiller mcp`).
    public func connect(serverExecutable: URL) throws {
        var config = try read() ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = ["command": serverExecutable.path, "args": ["mcp"]]
        config["mcpServers"] = servers
        try write(config)
    }

    public func disconnect() throws {
        guard var config = try read(), var servers = config["mcpServers"] as? [String: Any],
              servers[Self.serverName] != nil else { return }
        servers[Self.serverName] = nil
        config["mcpServers"] = servers
        try write(config)
    }

    private func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DistillerError.setupFailed("Claude Desktop's settings file isn't in the expected format, so Distiller left it alone: \(file.path)")
        }
        return object
    }

    private func write(_ config: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("before-distiller.bak")
        if fileManager.fileExists(atPath: file.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: file, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
