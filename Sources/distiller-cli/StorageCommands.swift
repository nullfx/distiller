import ArgumentParser
import Foundation
import DistillerCore

// MARK: - storage

struct StorageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Show or change where Wine builds and bottles are kept.",
        discussion: "The library, logs and settings always stay in the support folder. A drive's root gets a Distiller folder.",
        subcommands: [Show.self, Move.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show storage locations and their drives.")

        func run() throws {
            let paths = DistillerPaths()
            print("Support folder:  \(paths.root.path)")
            for kind in StorageKind.allCases {
                let location = paths.location(of: kind)
                let detail: String
                if let missing = paths.unavailable.first(where: { $0.kind == kind }) {
                    detail = "NOT AVAILABLE: \(missing.message)"
                } else if let volume = StorageVolume(containing: location) {
                    detail = "\(volume.format), \(volume.availableDescription)"
                } else {
                    detail = "unknown drive"
                }
                print("\(kind.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(location.path)  (\(detail))")
            }
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move Wine builds or bottles to another folder or drive.",
            discussion: "Copies across drives, then removes the originals. Quit the app and stop any games first."
        )

        @Argument(help: "What to move: wine or bottles.")
        var kind: StorageKind

        @Argument(help: "The destination folder. A drive's root gets a Distiller folder.")
        var folder: String

        func run() async throws {
            let destination = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            let settings = try await DistillerEngine.moveStorage(kind, to: destination, paths: DistillerPaths()) { step in
                print(step.message)
            }
            let paths = DistillerPaths(storage: settings)
            print("\(kind.displayName) are now in \(paths.location(of: kind).path)")
        }
    }
}

extension StorageKind: ExpressibleByArgument {}

// MARK: - bottles drives

struct BottleDrives: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drives",
        abstract: "List a bottle's drive letters, or map a Mac folder's drive to the next free letter."
    )

    @Argument(help: "The bottle ID, from 'distiller bottles'.")
    var bottle: String

    @Option(help: "Map the drive that holds this folder (D:, then E:, …).")
    var map: String?

    func run() throws {
        let engine = try makeEngine()
        let prefix = engine.bottles.prefix(of: try engine.bottles.bottle(id: bottle))
        if let map {
            let folder = URL(fileURLWithPath: (map as NSString).expandingTildeInPath, isDirectory: true)
            if let path = try DriveMapper.mapVolume(of: folder, in: prefix) {
                print("\(folder.path) is \(path)")
            } else {
                print("\(folder.path) is on the startup disk, which Wine reaches through Z:.")
            }
        }
        for mapping in DriveMapper.mappings(in: prefix) {
            print("\(mapping.letter.uppercased()):  \(mapping.target)\(mapping.isDynamic ? "  (added by Wine for a removable drive)" : "")")
        }
    }
}

// MARK: - games link-folder

struct GameLinkFolder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link-folder",
        abstract: "Use a game's original folder instead of the copy in its bottle.",
        discussion: """
            Compares the copy with the original first. Without --apply it only reports. With \
            --apply it deletes the copy, links the original into the bottle and maps its drive. \
            Files that exist only in the copy (often saves or settings) block --apply unless you \
            also pass --discard-copy-changes.
            """
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Argument(help: "The original game folder.")
    var folder: String

    @Option(help: "The user_folder step ID, when the recipe has more than one.")
    var step: String?

    @Flag(help: "Delete the copy and link the original.")
    var apply = false

    @Flag(help: "Apply even though the copy has files the original doesn't.")
    var discardCopyChanges = false

    func run() throws {
        let engine = try makeEngine()
        let entry = try engine.library.game(id: game)
        let original = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        let (_, copy) = try engine.userFolderLocation(of: entry, stepID: step)
        if APFSClone.isSymlink(copy) {
            print("The bottle already links to \((try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path)) ?? "a folder").")
        } else {
            let comparison = try engine.compareFolderCopy(of: entry, with: original, stepID: step)
            print("Copy in the bottle: \(copy.path) (\(ByteCountFormatter.string(fromByteCount: comparison.copyBytes, countStyle: .file)))")
            print("Files only in the copy, or a different size there: \(comparison.onlyInCopy.count)")
            for path in comparison.onlyInCopy.prefix(20) { print("  \(path)") }
            print("Files only in the original: \(comparison.onlyInOriginal.count)")
            for path in comparison.onlyInOriginal.prefix(20) { print("  \(path)") }
            guard apply else {
                print("Nothing changed. Run again with --apply to delete the copy and link the original.")
                return
            }
            if !comparison.matches && !discardCopyChanges {
                throw ValidationError("The copy has changes the original doesn't. Copy anything you need, or pass --discard-copy-changes.")
            }
        }
        guard apply else { return }
        let path = try engine.useFolderInPlace(for: entry, original: original, stepID: step)
        print("\(entry.title) now uses \(original.path), which the game sees as \(path).")
    }
}

// MARK: - games icon

struct GameIconCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icon",
        abstract: "Show, read, or set a game's icon.",
        discussion: "Without options, reads the icon from the game's program again and prints where it's saved."
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Option(help: "Use this image, .icns, .ico, or another program's (.exe) icon instead.")
    var set: String?

    @Flag(help: "Go back to the icon read from the game's program.")
    var reset = false

    func run() throws {
        let engine = try makeEngine()
        let entry = try engine.library.game(id: game)
        if let set {
            try engine.setCustomIcon(for: entry, from: URL(fileURLWithPath: (set as NSString).expandingTildeInPath))
        } else if reset {
            try engine.removeCustomIcon(for: entry)
            engine.refreshIcon(for: entry)
        } else if !engine.hasCustomIcon(entry), engine.refreshIcon(for: entry) == nil {
            print(engine.availability(of: entry).reason ?? "The program has no icon.")
        }
        print(engine.iconURL(for: entry).map { "Icon: \($0.path)\(engine.hasCustomIcon(entry) ? " (chosen by you)" : "")" } ?? "No icon.")
    }
}

// MARK: - mcp

struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a Model Context Protocol server so an assistant can help troubleshoot games.",
        discussion: """
            Speaks MCP over standard input and output; an MCP client starts it. The tools only read: \
            games, recipes, launch logs, the game's own logs, program inspection and this Mac's setup. \
            The assistant is off until you turn it on (distiller assistant on); \
            `distiller assistant setup` shows how to connect other clients.

            Claude Code:     claude mcp add distiller -- <path to distiller> mcp
            Claude Desktop:  add to claude_desktop_config.json under "mcpServers":
                             "distiller": { "command": "<path to distiller>", "args": ["mcp"] }
            """
    )

    func run() async throws {
        // Standard output carries protocol messages only; anything else goes to standard error.
        let engine = try makeEngine()
        let root = engine.paths.root
        let server = MCPServer(tools: AssistantTools(engine: engine), version: DistillerVersion.current) {
            StorageSettings.load(fromSupportFolder: root).isAssistantEnabled
        }
        let state = StorageSettings.load(fromSupportFolder: root).isAssistantEnabled ? "on" : "turned off in Settings"
        FileHandle.standardError.write(Data("Distiller MCP server ready (library: \(root.path); assistant \(state)).\n".utf8))
        for try await line in FileHandle.standardInput.bytes.lines {
            guard let response = server.handle(line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }
}

// MARK: - assistant

struct AssistantCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assistant",
        abstract: "Turn the AI troubleshooting assistant (distiller mcp) on or off, or show how to connect an AI app.",
        discussion: """
            on / off take effect at once, even for an assistant that's already connected.
            The assistant is off until you turn it on.
            Distiller doesn't change other apps' settings: add `<path to distiller> mcp` to your AI
            app's MCP servers and it starts Distiller's server when it needs it.
            setup [client] prints how, with this command's path:
            \(MCPClient.allCases.map(\.rawValue).joined(separator: ", ")).
            """
    )

    @Argument(help: "status, on, off or setup.")
    var action: String = "status"

    @Argument(help: "For setup: the client to explain (default: all of them).")
    var client: String?

    func run() throws {
        let root = DistillerPaths().root
        var settings = StorageSettings.load(fromSupportFolder: root)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        switch action {
        case "on", "off":
            settings.assistantEnabled = action == "on"
            try settings.save(toSupportFolder: root)
        case "status":
            break
        case "setup":
            try printSetup(MCPClientSetup(serverPath: executable.path), enabled: settings.isAssistantEnabled)
            return
        default:
            throw ValidationError("Choose status, on, off or setup.")
        }
        print("Assistant: \(settings.isAssistantEnabled ? "on" : "off")")
        print("Server: \(executable.path) mcp (see: distiller assistant setup)")
    }

    private func printSetup(_ setup: MCPClientSetup, enabled: Bool) throws {
        let clients: [MCPClient]
        if let client {
            guard let match = MCPClient(rawValue: client) else {
                throw ValidationError("Choose one of: \(MCPClient.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            clients = [match]
        } else {
            clients = MCPClient.allCases
        }
        if !enabled { print("The assistant is off; turn it on first with: distiller assistant on\n") }
        for client in clients {
            print("== \(client.name) ==")
            for (index, step) in setup.steps(for: client).enumerated() { print("\(index + 1). \(step)") }
            for snippet in setup.snippets(for: client) { print("\n\(snippet.label) (\(snippet.language)):\n\(snippet.text)") }
            print()
        }
    }
}

// MARK: - recipe community-check

struct RecipeCommunityCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "community-check",
        abstract: "Prove a recipe works for other players before submitting it.",
        discussion: """
            In a new bottle: downloads the game's official installer (game.installer.url), applies the \
            recipe's settings, runs the installer (follow its steps if it asks anything), asks which \
            installed program to launch, starts it, and asks whether it reached its login or menu. \
            A pass is saved with the game; `distiller recipe submit` then submits that checked recipe.
            """
    )

    @Argument(help: "The game ID.")
    var game: String

    @Flag(help: "Keep the test bottle afterwards (it's removed by default).")
    var keepBottle = false

    func run() async throws {
        let engine = try makeEngine()
        let entry = try engine.library.game(id: game)
        let prompts = CommunityCheckPrompts(
            chooseProgram: { programs, suggested in
                print("Installed programs:")
                for (index, program) in programs.prefix(20).enumerated() {
                    print("  \(index + 1). \(program.windowsPath)\(program == suggested ? "   ← suggested" : "")")
                }
                print("Program to launch [Enter for the suggestion, q to cancel]: ", terminator: "")
                guard let answer = readLine()?.trimmingCharacters(in: .whitespaces), answer.lowercased() != "q" else { return nil }
                if answer.isEmpty { return suggested }
                guard let number = Int(answer), (1...min(programs.count, 20)).contains(number) else { return nil }
                return programs[number - 1]
            },
            confirmRunning: { title, _ in
                // No screenshots from the command line; the app takes them.
                print("Did \(title) reach its login screen or menu? [y/n]: ", terminator: "")
                return CommunityCheckAnswer(works: readLine()?.lowercased().hasPrefix("y") == true)
            }
        )
        let updated = try await engine.runCommunityCheck(for: entry, prompts: prompts, keepBottle: keepBottle) { print($0) }
        if let check = updated.communityCheck {
            print("Community check passed. Installer SHA-256: \(check.installerSHA256). Launches \(check.recipe.launch?.exe ?? "?").")
        }
    }
}
