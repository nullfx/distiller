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
