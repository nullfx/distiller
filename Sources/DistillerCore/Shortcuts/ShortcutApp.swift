import Foundation

/// A game's shortcut app (`<Title>.app`): a tiny Mac app (the `DistillerShortcut` program, which
/// ships inside Distiller) that starts the game through Distiller's command line, so the game
/// opens like a Mac app of its own. Its bundle has the game's icon, runs in the background
/// (`LSUIElement`: no Dock icon of its own while it waits; the game shows its own), names the
/// game in `Contents/Resources/shortcut.json`, and is signed for this Mac (`codesign -s -`).
public enum ShortcutApp {
    public static let programName = "DistillerShortcut"
    static let manifestName = "shortcut.json"

    public struct Manifest: Codable, Equatable, Sendable {
        public var gameID: String
        public var title: String
        /// The Distiller that made it, tried first (another copy may be installed, such as an
        /// older release); found by bundle identifier if it's moved or gone.
        public var distillerApp: String?

        enum CodingKeys: String, CodingKey {
            case title
            case gameID = "game_id"
            case distillerApp = "distiller_app"
        }

        public init(gameID: String, title: String, distillerApp: String? = nil) {
            self.gameID = gameID
            self.title = title
            self.distillerApp = distillerApp
        }
    }

    public static func bundleIdentifier(for gameID: String) -> String {
        let safe = gameID.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return "com.nullfx.distiller.shortcut." + String(safe)
    }

    /// Whether `url` is a shortcut Distiller made (so it may be replaced).
    public static func isShortcut(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/\(manifestName)").path)
    }

    public static func manifest(of url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Resources/\(manifestName)")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Makes the shortcut at `destination` (a `.app` path), replacing an earlier shortcut there
    /// but nothing else. `program` is the `DistillerShortcut` program; `icon` any image Image I/O
    /// reads (the game's icon), or nil for the system's app icon.
    @discardableResult
    public static func create(gameID: String, title: String, icon: Data?, program: URL, at destination: URL,
                              distillerApp: URL? = nil, sign: Bool = true) async throws -> URL {
        let fileManager = FileManager.default
        guard destination.pathExtension == "app" else {
            throw DistillerError.invalidRecipe("A shortcut's name must end in .app.")
        }
        guard fileManager.isExecutableFile(atPath: program.path) else {
            throw DistillerError.componentNotFound("the shortcut program (\(programName)) in this copy of Distiller")
        }
        if fileManager.fileExists(atPath: destination.path), !isShortcut(destination) {
            throw DistillerError.setupFailed("\(destination.lastPathComponent) already exists and isn't a Distiller shortcut. Choose another name or place.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: program, to: contents.appendingPathComponent("MacOS/\(programName)"))

        var info: [String: Any] = [
            "CFBundleName": String(title.prefix(15)),
            "CFBundleDisplayName": title,
            "CFBundleIdentifier": bundleIdentifier(for: gameID),
            "CFBundleExecutable": programName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            // A game, as Distiller is: macOS's Games menu and app can show it (as the app that
            // started the game) rather than Distiller.
            "LSApplicationCategoryType": "public.app-category.games",
            "NSHumanReadableCopyright": "Opens \(title) with Distiller.",
        ]
        if let icon, let icns = ICNS.make(fromImage: icon) {
            try icns.write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(gameID: gameID, title: title, distillerApp: distillerApp?.path))
            .write(to: contents.appendingPathComponent("Resources/\(manifestName)"))

        if sign {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"),
                                                     arguments: ["--force", "--sign", "-", staging.path])
            guard result.status == 0 else {
                throw DistillerError.processFailed(command: "codesign \(destination.lastPathComponent)", status: result.status, logFile: nil)
            }
        }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }
}

extension DistillerEngine {
    /// Makes `game`'s shortcut app at `destination`, with its icon.
    @discardableResult
    public func createShortcut(for game: Game, program: URL, at destination: URL, distillerApp: URL? = nil) async throws -> URL {
        let icon = iconURL(for: game).flatMap { try? Data(contentsOf: $0) }
        return try await ShortcutApp.create(gameID: game.id, title: game.title, icon: icon, program: program, at: destination,
                                            distillerApp: distillerApp)
    }

    /// Whether a game is running now, however it was started (from Distiller, a shortcut, a
    /// launcher's window): a launcher while its bottle's Wine is up, a launcher's game as its
    /// launcher says, any other game while its program runs in its bottle.
    public func isGameRunning(_ game: Game, processes: BottleProcesses) -> Bool {
        guard isBottleActive(game, active: processes.active) else { return false }
        if game.launchedBy != nil { return launcherGameState(game, processes: processes).running }
        if isLauncher(game) { return true }
        guard let bottle = try? bottles.bottle(id: game.bottleID),
              let exe = resolve(game.recipe, overrides: game.overrides).launch?.exe else { return false }
        let name = exe.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").last.map { String($0).lowercased() } ?? ""
        guard !name.isEmpty else { return false }
        let prefix = bottles.prefix(of: bottle)
        let commands = processes.commands[prefix.path] ?? processes.commands[prefix.standardizedFileURL.path] ?? []
        return commands.contains { command in
            let program = Self.programPath(of: command).lowercased()
            return program.hasSuffix("\\" + name) || program.hasSuffix("/" + name) || program == name
        }
    }

    /// The program part of a command (its path up to `.exe`, spaces and all), else its first word.
    static func programPath(of command: String) -> String {
        if let exe = command.range(of: ".exe", options: .caseInsensitive) { return String(command[..<exe.upperBound]) }
        return command.split(separator: " ").first.map(String.init) ?? command
    }
}
