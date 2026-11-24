import ArgumentParser
import DistillerCore
import Foundation

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "Where Wine builds come from: list sources, add one for a tag a recipe names, install from it.",
        subcommands: [List.self, Files.self, Add.self, Install.self, Check.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the sources Distiller knows (its own, then yours).")

        func run() throws {
            let engine = try makeEngine()
            let sources = engine.componentSources
            for source in sources.all {
                let mine = sources.local.contains { $0.tag == source.tag } ? " (yours)" : ""
                let family = source.kind == .wine ? " family \(source.family)," : ""
                print("\(source.tag)\t\(source.kind.rawValue),\(family) github.com/\(source.get.githubRelease.repository), \(source.license)\(mine)")
            }
        }
    }

    struct Files: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the files in a GitHub repository's recent releases, with whether GitHub publishes a checksum.")

        @Argument(help: "owner/name, such as Sikarugir-App/Engines.")
        var repository: String

        func run() async throws {
            let setup = EnvironmentSetup(engine: try makeEngine())
            for file in try await setup.releaseFiles(repository: repository) {
                let size = file.size.map { " \($0 / 1_048_576) MB" } ?? ""
                print("\(file.release)\t\(file.name)\(size)\(file.sha256 == nil ? "  (no checksum)" : "")")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a source from a file (the format of components/<kind>/<tag>.yaml in the recipes repository).")

        @Argument(help: "The source's YAML file.")
        var file: String

        func run() throws {
            let engine = try makeEngine()
            let text = try String(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath), encoding: .utf8)
            let source = try ComponentSource.decode(yaml: text)
            let url = try engine.saveSource(source)
            print("Added \(source.tag) (\(url.path)). Install it with: distiller sources install \(source.tag)")
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download, check and install a Wine build from a source.")

        @Argument(help: "The source's tag.")
        var tag: String

        @Option(help: "A particular file from its releases, instead of the newest matching one.")
        var file: String?

        func run() async throws {
            let engine = try makeEngine()
            guard let source = engine.componentSources.source(tag: tag) else {
                throw ValidationError("No source is tagged \(tag). See: distiller sources list")
            }
            let setup = EnvironmentSetup(engine: engine)
            var chosen: ReleaseFile?
            if let file {
                chosen = try await setup.releaseFiles(repository: source.get.githubRelease.repository).first { $0.name == file }
                guard chosen != nil else { throw ValidationError("\(file) isn't in github.com/\(source.get.githubRelease.repository)'s releases.") }
            }
            let result = try await setup.install(source, file: chosen) { print($0) }
            print("Installed \(result.component.manifest.displayName) (\(result.component.id)), checked against GitHub's checksum.")
            if let from = result.librariesFrom { print("  Added \(result.librariesAdded) libraries from \(from).") }
            print("  D3DMetal: \(result.containsD3DMetal ? "included (its publisher answers for it under Apple's terms)" : "not included")")
            switch result.exportsMacDriverFunctions {
            case true?: print("  Runs D3DMetal and DXMT: yes (exports the macOS driver functions they need)")
            case false?: print("  Runs D3DMetal and DXMT: no (its macOS driver doesn't export the functions they need)")
            case nil: print("  Runs D3DMetal and DXMT: couldn't tell")
            }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check that every library an installed Wine build's programs load can be found.")

        @Argument(help: "The build, as id@version or just id (every installed version).")
        var component: String

        func run() throws {
            let engine = try makeEngine()
            let builds = engine.components.installed().filter {
                $0.manifest.kind == .wine && ($0.id == component || $0.manifest.id == component)
            }
            guard !builds.isEmpty else { throw ValidationError("No Wine build \(component) is installed. See: distiller components list") }
            var failed = false
            for build in builds {
                let fallback = build.manifest.effectiveLibraryPaths.map { build.directory.appendingPathComponent($0) }
                let missing = MachODependencies.missingRPathLibraries(in: build.directory, fallback: fallback)
                if missing.isEmpty {
                    print("\(build.id): every library is found" + (fallback.isEmpty ? "" : " (with \(build.manifest.effectiveLibraryPaths.joined(separator: ", ")) as a library folder)"))
                } else {
                    failed = true
                    print("\(build.id): can't find")
                    for (library, users) in missing.sorted(by: { $0.key < $1.key }) {
                        print("  \(library), needed by \(users.prefix(3).joined(separator: ", "))\(users.count > 3 ? " and \(users.count - 3) more" : "")")
                    }
                }
            }
            if failed { throw ExitCode.failure }
        }
    }
}
