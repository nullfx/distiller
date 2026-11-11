import ArgumentParser
import Foundation
import DistillerCore

extension ComponentUpdateMode: ExpressibleByArgument {}

extension ComponentsCommand {
    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Look for newer Wine builds, graphics layers and winetricks.")

        func run() async throws {
            let setup = EnvironmentSetup(engine: try makeEngine())
            let check = await setup.checkForUpdates()
            for (name, reason) in check.failures.sorted(by: { $0.key < $1.key }) {
                print("Couldn't check \(name): \(reason)")
            }
            if check.updates.isEmpty {
                print("Everything is up to date.")
                return
            }
            for update in check.updates {
                print(describe(update))
            }
            print("Install with: distiller components update [<id>]")
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install component updates, then remove versions nothing needs.",
            discussion: "Without an id, installs every update except components you're keeping on an older version (see 'distiller components use')."
        )

        @Argument(help: "A component id from 'distiller components check', such as wine-staging. Omit for all.")
        var id: String?

        @Flag(help: "Keep old versions even when nothing needs them.")
        var keepOld = false

        func run() async throws {
            let engine = try makeEngine()
            let setup = EnvironmentSetup(engine: engine)
            let check = await setup.checkForUpdates()
            let chosen = id.map { id in check.updates.filter { $0.id == id } } ?? EnvironmentSetup.automatic(check.updates)
            if let id, chosen.isEmpty {
                print(check.updates.isEmpty ? "Everything is up to date." : "No update for \(id). Updates: \(check.updates.map(\.id).joined(separator: ", "))")
                return
            }
            if chosen.isEmpty { print("Nothing to install."); return }
            for update in chosen {
                print("Installing \(update.displayName) \(update.availableVersion)…")
                let installed = try await setup.install(update)
                print("  Installed \(installed.id); it's now the active \(update.displayName).")
            }
            guard !keepOld else { return }
            for removed in await engine.removeUnusedComponents() {
                print("Removed \(removed.id), which nothing needs any more.")
            }
        }
    }

    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make an installed version the active one.",
            discussion: """
            New games use the active version, and games that follow updates move to it. Making an
            older version active keeps that component there: automatic updates skip it until you
            make the newest version active again.
              distiller components use wine-staging@11.21
            """
        )

        @Argument(help: "A component as id@version, from 'distiller components list'.")
        var component: String

        func run() throws {
            let engine = try makeEngine()
            guard let match = engine.components.installed().first(where: { $0.id == component }) else {
                throw ValidationError("No installed component \(component). See 'distiller components list'.")
            }
            try engine.components.makeActive(match)
            print("\(match.manifest.displayName) is now the active \(match.manifest.id).")
        }
    }

    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove component versions nothing needs any more.")

        @Flag(help: "Only list what would be removed.")
        var dryRun = false

        func run() async throws {
            let engine = try makeEngine()
            if dryRun {
                let unused = engine.unusedComponents()
                print(unused.isEmpty ? "Nothing to remove." : unused.map { "Would remove \($0.id)" }.joined(separator: "\n"))
                return
            }
            let removed = await engine.removeUnusedComponents()
            print(removed.isEmpty ? "Nothing to remove." : removed.map { "Removed \($0.id)" }.joined(separator: "\n"))
        }
    }

    struct Updates: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change how Distiller keeps components up to date.",
            discussion: "ask: check daily and show updates (the default). auto: install them by themselves. off: don't check."
        )

        @Argument(help: "ask, auto or off. Omit to show the current setting.")
        var mode: ComponentUpdateMode?

        func run() throws {
            let engine = try makeEngine()
            var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
            if let mode {
                settings.componentUpdates = mode
                try settings.save(toSupportFolder: engine.paths.root)
            }
            print("Component updates: \(settings.effectiveComponentUpdates.rawValue) (\(settings.effectiveComponentUpdates.displayName)).")
            if let last = settings.lastComponentCheck {
                print("Last checked: \(last.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
    }
}

func describe(_ update: ComponentUpdate) -> String {
    let size = update.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
    let held = update.heldVersion.map { "; you're keeping \($0) active" } ?? ""
    return "\(update.id)\t\(update.displayName) \(update.installedVersion) → \(update.availableVersion)\(size)\(held)"
}

// MARK: - app

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Check for a newer Distiller, from the repository this copy was built from.",
        subcommands: [Check.self, Download.self],
        defaultSubcommand: Check.self
    )

    static func updater() throws -> AppUpdater {
        guard let repository = AppUpdater.configuredRepository else {
            throw DistillerError.setupFailed("This build doesn't say where its updates come from (run the distiller inside Distiller.app).")
        }
        return AppUpdater(repository: repository)
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Say whether a newer Distiller is available.")

        func run() async throws {
            let updater = try AppCommand.updater()
            let release = try await updater.latestRelease()
            if AppUpdater.isNewer(release.version, than: DistillerVersion.current) {
                print("Distiller \(release.version) is available (you have \(DistillerVersion.current)): \(release.page.absoluteString)")
                print("Install it from Settings ▸ Updates in the app, or download it with: distiller app download")
            } else {
                print("Distiller \(DistillerVersion.current) is up to date (latest release on github.com/\(updater.repository): \(release.version)).")
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download the latest Distiller.dmg and check it, without installing it.",
            discussion: "Checks the release's checksum, and that the app is signed by the same developer as this copy and notarized. Installing (which replaces the app) is done from the app's Settings ▸ Updates, or by opening the disk image."
        )

        @Option(help: "Where to save Distiller.dmg (default: ~/Downloads).")
        var to: String?

        func run() async throws {
            let updater = try AppCommand.updater()
            guard let current = DistillerVersion.appBundle else {
                throw DistillerError.setupFailed("Run the distiller inside Distiller.app, so the download can be checked against it.")
            }
            let release = try await updater.latestRelease()
            let folder = URL(fileURLWithPath: ((to ?? "~/Downloads") as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("Distiller \(release.version)", isDirectory: true)
            print("Downloading Distiller \(release.version)…")
            let image = try await updater.download(release, into: folder)
            print("Checking it…")
            let mounted = try await AppBundleCheck.attach(image)
            do {
                try await AppBundleCheck.verify(mounted.app, replacing: current, version: release.version)
            } catch {
                await AppBundleCheck.detach(mounted.mountPoint)
                print("Not using \(image.path).")
                throw error
            }
            await AppBundleCheck.detach(mounted.mountPoint)
            print("Checked: \(image.path)")
        }
    }
}

// MARK: - games versions

struct GameVersionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "versions",
        abstract: "Show or choose the Wine build, graphics layer and winetricks a game uses.",
        discussion: """
        A game follows the active version of each (see 'distiller components'), or stays on one you
        choose. Staying keeps a working game as it is when the others update, but it may miss fixes
        or break with newer recipes. Wine can only stay on the build the game's bottle uses now or a
        newer one.
          distiller games versions <game> --wine wine-staging@11.21
          distiller games versions <game> --wine follow
        """
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Option(help: "id@version to stay on, or 'follow'.")
    var wine: String?

    @Option(help: "id@version to stay on, or 'follow'.")
    var graphics: String?

    @Option(help: "id@version to stay on, or 'follow'.")
    var winetricks: String?

    func run() throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        let installed = engine.components.installed()
        for (kind, value) in [(ComponentKind.wine, wine), (.graphics, graphics), (.winetricks, winetricks)] {
            guard let value else { continue }
            if value == "follow" {
                try engine.setStayOn(kind, nil, for: entry)
            } else {
                guard let component = installed.first(where: { $0.id == value && $0.manifest.kind == kind }) else {
                    throw ValidationError("No installed \(kind.rawValue) component \(value). See 'distiller components list'.")
                }
                try engine.setStayOn(kind, component, for: entry)
            }
        }
        let versions = try engine.versions(for: entry)
        for choice in [versions.wine, versions.graphics, versions.winetricks].compactMap({ $0 }) {
            let current = choice.current?.id ?? "none installed"
            let mode = choice.stayOn != nil ? "stays on it" : "follows updates"
            let others = choice.options.map(\.id).filter { $0 != choice.current?.id }
            print("\(choice.kind.rawValue)\t\(current)\t\(mode)\(others.isEmpty ? "" : "\t(also installed: \(others.joined(separator: ", ")))")")
        }
    }
}

// MARK: - games restore

struct GameRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Show a game's restore point (its bottle from before it moved to a newer Wine), or act on it.",
        discussion: "How long restore points are kept: settings.json restore_point_days (default 7; 0 until you confirm the game works; -1 until you remove it)."
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Flag(help: "The game works on its new Wine: remove the restore point (unless you keep them until removed).")
    var works = false

    @Flag(help: "Put the restore point back and keep the game on the Wine it was on.")
    var rollback = false

    @Flag(help: "Remove the restore point.")
    var discard = false

    func run() async throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        let bottle = try engine.bottles.bottle(id: entry.bottleID)
        guard let point = engine.bottles.restorePoint(of: bottle) else {
            print("\(entry.title) has no restore point.")
            return
        }
        if rollback {
            try await engine.rollBack(entry)
            print("\(entry.title) is back on \(RestorePoint.describe(point.fromWine)), and stays there (distiller games versions \(entry.id) --wine follow to move on again).")
        } else if works {
            try engine.confirmWineMove(entry)
            print(engine.bottles.restorePoint(of: bottle) == nil ? "Removed the restore point." : "Noted; the restore point stays until you remove it.")
        } else if discard {
            try engine.bottles.discardRestorePoint(of: bottle)
            print("Removed the restore point.")
        } else {
            print("Saved \(point.createdAt.formatted(date: .abbreviated, time: .shortened)), before moving from \(RestorePoint.describe(point.fromWine)) to \(RestorePoint.describe(point.toWine)).")
            print("--works, --rollback or --discard.")
        }
    }
}

// MARK: - games rebuild

struct GameRebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Rebuild a game's bottle with the current components, or decide on a rebuild.",
        discussion: """
        Installs the game's recipe into a new bottle with the active Wine build, graphics layer and
        winetricks, then switches the game to it; the old bottle is kept until you decide (--keep
        moves it to the Trash, --switch-back returns to it). Files and folders the recipe asked for
        are reused from the old bottle where possible; supply others with --file / --folder id=path.
        Anything the game keeps inside its bottle (saves under C:\\users, settings, a launcher's
        sign-in) isn't carried over.
        """
    )

    @Argument(help: "The game ID, from 'distiller games'.")
    var game: String

    @Flag(help: "Keep the rebuilt bottle and move the old one to the Trash.")
    var keep = false

    @Flag(help: "Go back to the old bottle and remove the rebuilt one.")
    var switchBack = false

    @Option(name: .customLong("file"), help: "A file for a user_file or user_download step, as id=path.")
    var files: [String] = []

    @Option(name: .customLong("folder"), help: "A folder for a user_folder step, as id=path.")
    var folderArguments: [String] = []

    func run() async throws {
        let engine = try makeEngine()
        let entry = try findGame(game, in: engine)
        if keep {
            try engine.keepRebuild(entry)
            print("Kept the rebuilt bottle; the old one is in the Trash.")
            return
        }
        if switchBack {
            _ = try engine.switchBack(entry)
            print("\(entry.title) is back in its old bottle; the rebuilt one is in the Trash.")
            return
        }
        var supplied = try engine.rebuildItems(for: entry)
        for item in files {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--file takes id=path, but got \(item).") }
            supplied.files[parts[0]] = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath)
        }
        for item in folderArguments {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--folder takes id=path, but got \(item).") }
            supplied.folders[parts[0]] = UserFolderSource(url: URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath))
        }
        var missing: [String] = []
        for step in entry.recipe.install ?? [] {
            switch step {
            case .userFile(let file) where supplied.files[file.id] == nil: missing.append("--file \(file.id)=<path> (\(file.prompt))")
            case .userDownload(let download) where supplied.files[download.id] == nil: missing.append("--file \(download.id)=<path> (\(download.prompt))")
            case .userFolder(let folder) where supplied.folders[folder.id] == nil: missing.append("--folder \(folder.id)=<path> (\(folder.prompt))")
            default: continue
            }
        }
        guard missing.isEmpty else {
            throw ValidationError("The old bottle doesn't have everything the recipe needs. Add:\n  " + missing.joined(separator: "\n  "))
        }
        let rebuilt = try await engine.rebuild(entry, supplied: supplied) { progress in
            print("[\(progress.step)/\(progress.total)] \(progress.message)")
        }
        print("Rebuilt \(rebuilt.title)'s bottle. Play it; then 'distiller games rebuild \(rebuilt.id) --keep' (or --switch-back).")
    }
}
