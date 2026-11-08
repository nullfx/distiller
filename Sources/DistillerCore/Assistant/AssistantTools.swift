import Foundation

/// The result of one assistant tool call: text for the model, and whether it failed.
public struct AssistantToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// The tools an assistant can use to troubleshoot games: served to MCP clients by
/// `distiller mcp`, and meant for the in-app advisor's tool calling too (design: "Assisted
/// recipe creation").
///
/// These are read-only. Reading is limited to Distiller's own files, a game's bottle and
/// the game's folder, text only, with size caps, and the home folder is shown as `~`.
public final class AssistantTools: @unchecked Sendable {
    public let engine: DistillerEngine

    /// Caps that keep responses small enough for a model's context.
    static let maxLines = 2000
    static let defaultLines = 300
    static let maxReadBytes = 2 * 1024 * 1024
    static let maxResponseCharacters = 60_000

    public init(engine: DistillerEngine) {
        self.engine = engine
    }

    // MARK: Definitions

    public struct Definition: @unchecked Sendable {
        public var name: String
        public var title: String
        public var description: String
        /// A JSON Schema object.
        public var inputSchema: [String: Any]
        public var readOnly: Bool
    }

    private static let gameID: [String: Any] = ["type": "string", "description": "The game's ID, from list_games."]
    private static let logShaping: [String: Any] = [
        "tail": ["type": "integer", "description": "How many lines to return from the end (default \(defaultLines), at most \(maxLines))."],
        "filter": ["type": "string", "description": "Only lines containing this text (case-insensitive), such as \"err:\" or \"dll\"."],
        "dedupe": ["type": "boolean", "description": "Merge lines that differ only in numbers (timestamps, addresses) and show how often each occurred. Default true."],
    ]

    public static let definitions: [Definition] = [
        Definition(
            name: "list_games",
            title: "List games",
            description: "Lists the games in the player's Distiller library: ID, title, recipe, graphics layer, whether it can be played now (and why not), and when it was last played.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            readOnly: true
        ),
        Definition(
            name: "get_game",
            title: "Get a game's setup",
            description: "Shows how a game is set up: its recipe (YAML), the settings resolved for this Mac (graphics layer, Windows version, winetricks, DLL overrides, environment, launch command), its bottle and Wine build, its drive letters, where its program and folders really are, and whether it can be played now.",
            inputSchema: ["type": "object", "properties": ["game_id": gameID], "required": ["game_id"]],
            readOnly: true
        ),
        Definition(
            name: "read_launch_log",
            title: "Read a launch log",
            description: "Reads the Wine output Distiller saved when the game was last launched (or an earlier launch). Wine's own debug output is off by default, so errors from the game's components (for example an embedded Chromium) are the main signal. Lists the available logs first.",
            inputSchema: [
                "type": "object",
                "properties": ["game_id": gameID, "log": ["type": "string", "description": "A log file name from the list; default is the newest."]]
                    .merging(logShaping) { first, _ in first },
                "required": ["game_id"],
            ],
            readOnly: true
        ),
        Definition(
            name: "list_game_logs",
            title: "List the game's own logs",
            description: "Lists log-like files the game itself writes (.log, .txt, crash dumps and similar) in its folder and in its bottle's AppData, newest first, with sizes and times. Use read_game_file to read one.",
            inputSchema: ["type": "object", "properties": ["game_id": gameID], "required": ["game_id"]],
            readOnly: true
        ),
        Definition(
            name: "read_game_file",
            title: "Read a game file",
            description: "Reads a text file from the game's folder or its bottle, such as a log from list_game_logs or a config file. The path is relative to the game folder (\"debug.log\") or a Windows path on C: (\"C:\\users\\...\"). Binary files are refused.",
            inputSchema: [
                "type": "object",
                "properties": ["game_id": gameID, "path": ["type": "string", "description": "Relative to the game folder, or a C:\\ path in the bottle."]]
                    .merging(logShaping) { first, _ in first },
                "required": ["game_id", "path"],
            ],
            readOnly: true
        ),
        Definition(
            name: "inspect_program",
            title: "Inspect a program",
            description: "Reads a Windows program's headers without running it: 32- or 64-bit, imported DLLs, graphics APIs, engine (Unity, Unreal, .NET), and Distiller's suggested graphics layer, Windows version and winetricks. Defaults to the game's launch program.",
            inputSchema: [
                "type": "object",
                "properties": ["game_id": gameID, "path": ["type": "string", "description": "Optional: another .exe or .dll, relative to the game folder or a C:\\ path."]],
                "required": ["game_id"],
            ],
            readOnly: true
        ),
        Definition(
            name: "get_environment",
            title: "Describe this Mac's setup",
            description: "Describes the Mac and Distiller's setup: chip, GPU cores, memory, macOS, Rosetta; installed Wine builds, graphics layers (D3DMetal, DXMT, DXVK) and winetricks; and where Wine and bottles are stored.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            readOnly: true
        ),
    ]

    // MARK: Calls

    public func call(_ name: String, arguments: [String: Any]) -> AssistantToolResult {
        do {
            let text: String
            switch name {
            case "list_games": text = try listGames()
            case "get_game": text = try getGame(try game(arguments))
            case "read_launch_log": text = try readLaunchLog(try game(arguments), arguments: arguments)
            case "list_game_logs": text = try listGameLogs(try game(arguments))
            case "read_game_file": text = try readGameFile(try game(arguments), arguments: arguments)
            case "inspect_program": text = try inspectProgram(try game(arguments), path: arguments["path"] as? String)
            case "get_environment": text = try environment()
            default: return AssistantToolResult("There's no tool called \(name).", isError: true)
            }
            return AssistantToolResult(Self.limit(redact(text)))
        } catch {
            return AssistantToolResult(redact(error.localizedDescription), isError: true)
        }
    }

    private func game(_ arguments: [String: Any]) throws -> Game {
        guard let id = arguments["game_id"] as? String, !id.isEmpty else {
            throw AssistantError("game_id is required. Use list_games to find it.")
        }
        do {
            return try engine.library.game(id: id)
        } catch {
            throw AssistantError("There's no game with ID \(id). Use list_games to find it.")
        }
    }

    // MARK: Tools

    private func listGames() throws -> String {
        let games = engine.library.load()
        if games.isEmpty { return "The library is empty." }
        let rows: [[String: Any]] = games.map { game in
            let resolved = engine.resolve(game.recipe, overrides: game.overrides)
            var row: [String: Any] = [
                "id": game.id,
                "title": game.title,
                "recipe": "\(game.recipe.game.slug)/\(game.recipe.id)",
                "graphics": resolved.graphics.displayName,
                "availability": Self.describe(engine.availability(of: game)),
                "seconds_played": Int(game.secondsPlayed),
            ]
            if let last = game.lastPlayedAt { row["last_played"] = ISO8601DateFormatter().string(from: last) }
            return row
        }
        return try Self.json(["games": rows])
    }

    private func getGame(_ game: Game) throws -> String {
        let bottle = try engine.bottles.bottle(id: game.bottleID)
        let root = engine.bottles.root(of: bottle)
        let resolved = engine.resolve(game.recipe, overrides: game.overrides)
        var info: [String: Any] = [
            "id": game.id,
            "title": game.title,
            "availability": Self.describe(engine.availability(of: game)),
            "bottle": ["id": bottle.id, "path": root.path, "wine_build": bottle.wine],
            "drives": DriveMapper.mappings(in: engine.bottles.prefix(of: bottle)).map {
                ["letter": "\($0.letter.uppercased()):", "mac_path": $0.target, "added_by_wine": $0.isDynamic]
            },
            "resolved_for_this_mac": try Self.jsonObject(resolved),
        ]
        if let exe = resolved.launch?.exe, let url = try? BottlePath.resolve(exe, in: root) {
            info["launch_program"] = ["windows_path": exe, "mac_path": url.followingSymlinks.path]
        }
        info["game_folders"] = gameFolders(game).map { ["mac_path": $0.path] }
        if let overrides = game.overrides { info["local_overrides"] = try Self.jsonObject(overrides) }
        let yaml = (try? RecipeLoader.encode(game.recipe)) ?? "(couldn't encode the recipe)"
        return try Self.json(info) + "\n\nRecipe (YAML):\n" + yaml
    }

    private func readLaunchLog(_ game: Game, arguments: [String: Any]) throws -> String {
        let logs = launchLogs(for: game)
        guard !logs.isEmpty else { return "\(game.title) has no launch logs yet. They appear after the first launch." }
        let chosen: URL
        if let name = arguments["log"] as? String, !name.isEmpty {
            guard let match = logs.first(where: { $0.lastPathComponent == name }) else {
                throw AssistantError("No log named \(name). Available: \(logs.map(\.lastPathComponent).joined(separator: ", "))")
            }
            chosen = match
        } else {
            chosen = logs[0]
        }
        let listing = logs.prefix(10).map { "  \($0.lastPathComponent)\($0 == chosen ? "  ← shown" : "")" }.joined(separator: "\n")
        let body = try Self.readText(chosen, arguments: arguments)
        return "Launch logs, newest first:\n\(listing)\n\n\(body)"
    }

    private func listGameLogs(_ game: Game) throws -> String {
        var found: [(url: URL, root: URL, modified: Date, size: Int64)] = []
        for root in logRoots(game) {
            for (url, modified, size) in Self.logLikeFiles(in: root.url, depth: root.depth) {
                found.append((url, root.url, modified, size))
            }
        }
        if found.isEmpty { return "No log-like files were found in \(game.title)'s folder or bottle." }
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = found.sorted { $0.modified > $1.modified }.prefix(60).map { item in
            [
                "path": displayPath(item.url, game: game),
                "modified": formatter.string(from: item.modified),
                "size": ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                "text": !Self.isBinary(item.url),
            ]
        }
        return try Self.json(["files": rows])
    }

    private func readGameFile(_ game: Game, arguments: [String: Any]) throws -> String {
        guard let path = arguments["path"] as? String, !path.isEmpty else { throw AssistantError("path is required.") }
        let url = try resolveGamePath(path, game: game)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AssistantError("\(path) doesn't exist.") }
        if Self.isBinary(url) { throw AssistantError("\(path) isn't a text file, so it can't be read here.") }
        return "\(displayPath(url, game: game)):\n\n" + (try Self.readText(url, arguments: arguments))
    }

    private func inspectProgram(_ game: Game, path: String?) throws -> String {
        let program: URL
        if let path, !path.isEmpty {
            program = try resolveGamePath(path, game: game)
        } else {
            let bottle = try engine.bottles.bottle(id: game.bottleID)
            guard let exe = engine.resolve(game.recipe, overrides: game.overrides).launch?.exe else {
                throw AssistantError("\(game.title) has no launch program yet. Pass a path to inspect.")
            }
            program = try BottlePath.resolve(exe, in: engine.bottles.root(of: bottle)).followingSymlinks
        }
        guard FileManager.default.fileExists(atPath: program.path) else {
            throw AssistantError(engine.availability(of: game).reason ?? "\(program.path) doesn't exist.")
        }
        let inspection = GameInspector.inspect(executable: program, installedGraphics: engine.components.availableGraphics())
        var info: [String: Any] = [
            "program": program.path,
            "machine": inspection.machine?.rawValue ?? "not a Windows program",
            "graphics_apis": inspection.apis.map(\.displayName),
            "is_dotnet": inspection.isDotNet,
            "suggested": [
                "graphics": inspection.suggestedGraphics.displayName,
                "windows_version": inspection.suggestedWindowsVersion,
                "winetricks": inspection.suggestedWinetricks,
            ],
            "findings": inspection.findings,
        ]
        if let engineName = inspection.engine { info["engine"] = engineName }
        if let pe = PEFile.read(program) { info["imports"] = pe.imports.sorted() }
        return try Self.json(info)
    }

    private func environment() throws -> String {
        let hardware = engine.hardware
        let paths = engine.paths
        let components: [[String: Any]] = engine.components.installed().map {
            ["id": $0.id, "kind": $0.manifest.kind.rawValue, "name": $0.manifest.displayName, "arch": $0.manifest.arch.rawValue]
        }
        let storage: [[String: Any]] = StorageKind.allCases.map { kind in
            let location = paths.location(of: kind)
            var row: [String: Any] = ["what": kind.displayName, "path": location.path]
            if let missing = paths.unavailable.first(where: { $0.kind == kind }) {
                row["problem"] = missing.message
            } else if let volume = StorageVolume(containing: location) {
                row["drive"] = "\(volume.name) (\(volume.format), \(volume.availableDescription))"
            }
            return row
        }
        return try Self.json([
            "mac": [
                "summary": hardware.summary,
                "hardware_key": hardware.hardwareKey,
                "chip": hardware.chip,
                "gpu_cores": hardware.gpuCores as Any,
                "memory_gb": hardware.memoryGB,
                "macos": hardware.macOS,
                "rosetta": hardware.rosetta,
            ],
            "components": components,
            "graphics_available": engine.components.availableGraphics().map(\.displayName).sorted(),
            "storage": storage,
        ])
    }

    // MARK: Locations

    /// Folders the game was set up from (its `user_folder` steps), followed through links.
    private func gameFolders(_ game: Game) -> [URL] {
        guard let bottle = try? engine.bottles.bottle(id: game.bottleID) else { return [] }
        let root = engine.bottles.root(of: bottle)
        var folders: [URL] = []
        for case .userFolder(let folder) in game.recipe.install ?? [] {
            if let url = try? BottlePath.resolve(folder.to, in: root) { folders.append(url.followingSymlinks) }
        }
        if folders.isEmpty, let exe = engine.resolve(game.recipe, overrides: game.overrides).launch?.exe,
           let url = try? BottlePath.resolve(exe, in: root) {
            folders.append(url.followingSymlinks.deletingLastPathComponent())
        }
        return folders
    }

    private func logRoots(_ game: Game) -> [(url: URL, depth: Int)] {
        var roots = gameFolders(game).map { (url: $0, depth: 2) }
        if let bottle = try? engine.bottles.bottle(id: game.bottleID) {
            let users = engine.bottles.prefix(of: bottle).appendingPathComponent("drive_c/users", isDirectory: true)
            for account in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
                for folder in ["AppData/Local", "AppData/Roaming", "AppData/LocalLow", "Documents"] {
                    roots.append((account.appendingPathComponent(folder), 4))
                }
            }
        }
        return roots
    }

    /// Places the assistant may read: the game's folders and its bottle.
    private func allowedRoots(_ game: Game) -> [URL] {
        var roots = gameFolders(game)
        if let bottle = try? engine.bottles.bottle(id: game.bottleID) {
            roots.append(engine.bottles.root(of: bottle).followingSymlinks)
        }
        return roots
    }

    private func resolveGamePath(_ path: String, game: Game) throws -> URL {
        let candidate: URL
        let text = path.replacingOccurrences(of: "\\", with: "/")
        if text.count >= 2, text.dropFirst().first == ":" {
            let bottle = try engine.bottles.bottle(id: game.bottleID)
            candidate = try BottlePath.resolve(path, in: engine.bottles.root(of: bottle))
        } else {
            guard let folder = gameFolders(game).first else { throw AssistantError("\(game.title) has no game folder; use a C:\\ path.") }
            let parts = text.split(separator: "/")
            guard !parts.contains(where: { $0 == ".." }), !text.hasPrefix("/"), !text.hasPrefix("~") else {
                throw AssistantError("Paths must stay inside the game's folder or bottle.")
            }
            candidate = parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
        }
        let real = candidate.followingSymlinks
        guard allowedRoots(game).contains(where: { real.path == $0.path || real.path.hasPrefix($0.path + "/") }) else {
            throw AssistantError("Paths must stay inside the game's folder or bottle.")
        }
        return real
    }

    private func displayPath(_ url: URL, game: Game) -> String {
        if let bottle = try? engine.bottles.bottle(id: game.bottleID),
           let windows = BottlePath.windowsPath(for: url, in: engine.bottles.root(of: bottle).followingSymlinks) {
            return windows
        }
        for folder in gameFolders(game) where url.path.hasPrefix(folder.path + "/") {
            return String(url.path.dropFirst(folder.path.count + 1))
        }
        return url.path
    }

    private func launchLogs(for game: Game) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: engine.paths.logs, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("\(game.id)-") && $0.pathExtension == "log" }
            .sorted { Self.modified($0) > Self.modified($1) }
    }

    // MARK: Text helpers

    static let logExtensions: Set<String> = ["log", "txt", "dmp", "mdmp", "json", "xml", "ini", "cfg"]

    static func logLikeFiles(in folder: URL, depth: Int) -> [(URL, Date, Int64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [(URL, Date, Int64)] = []
        for case let url as URL in enumerator {
            if enumerator.level > depth { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let name = url.lastPathComponent.lowercased()
            let looksLikeLog = name.hasSuffix(".log") || name.hasSuffix(".dmp") || name.hasSuffix(".mdmp")
                || name.contains("crash") || name.contains("debug") || name.contains("error")
                || (logExtensions.contains(url.pathExtension.lowercased()) && name.contains("log"))
            guard looksLikeLog else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0)))
            if files.count >= 500 { break }
        }
        return files
    }

    static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return head.contains(0)
    }

    /// The end of a text file, filtered and deduplicated as asked.
    static func readText(_ url: URL, arguments: [String: Any]) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = max(0, size - Int64(maxReadBytes))
        try handle.seek(toOffset: UInt64(start))
        var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let filter = arguments["filter"] as? String, !filter.isEmpty {
            lines = lines.filter { $0.localizedCaseInsensitiveContains(filter) }
        }
        if (arguments["dedupe"] as? Bool) ?? true { lines = dedupe(lines) }
        let tail = min(max((arguments["tail"] as? Int) ?? defaultLines, 1), maxLines)
        let shown = lines.suffix(tail)
        var header = "\(lines.count) line\(lines.count == 1 ? "" : "s")"
        if shown.count < lines.count { header += ", showing the last \(shown.count)" }
        if start > 0 { header += "; only the last \(ByteCountFormatter.string(fromByteCount: Int64(maxReadBytes), countStyle: .file)) of the file was read" }
        return "[\(header)]\n" + shown.joined(separator: "\n")
    }

    /// Merges lines that differ only in their digits, keeping the first one's position and
    /// adding "(×N)". Log noise like repeated crash lines with new timestamps collapses to one.
    static func dedupe(_ lines: [String]) -> [String] {
        var order: [String] = []
        var first: [String: String] = [:]
        var counts: [String: Int] = [:]
        for line in lines {
            let key = line.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
            if counts[key] == nil {
                order.append(key)
                first[key] = line
            }
            counts[key, default: 0] += 1
        }
        return order.map { key in
            let count = counts[key] ?? 1
            return count > 1 ? "\(first[key] ?? key)  (×\(count))" : (first[key] ?? key)
        }
    }

    // MARK: Output helpers

    static func describe(_ availability: GameAvailability) -> String {
        switch availability {
        case .ready: return "ready"
        case .needsSetup: return "needs setup: no launch program chosen"
        case .unavailable(let reason): return "can't play: \(reason)"
        }
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func redact(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    static func limit(_ text: String) -> String {
        guard text.count > maxResponseCharacters else { return text }
        return "[cut to the last \(maxResponseCharacters) characters]\n" + String(text.suffix(maxResponseCharacters))
    }
}

struct AssistantError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
