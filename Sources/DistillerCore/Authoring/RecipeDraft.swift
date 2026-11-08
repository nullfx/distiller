import Foundation

/// The choices a player makes while creating a recipe, turned into a `Recipe` by `makeRecipe()`.
///
/// Three starting points:
/// - `.folder`: a game already on the Mac. The recipe asks each player for their own copy
///   of that folder with a `user_folder` step and launches the chosen program inside it.
/// - `.installer`: a Windows installer. The recipe asks for the installer with `user_file`
///   and runs it; the program to launch is picked after the installer has run.
/// - `.manual`: an empty bottle with the chosen settings. The player installs things
///   themselves; installers they run from Distiller are recorded as recipe steps.
public struct RecipeDraft: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case folder(URL)
        case installer(URL)
        case manual
    }

    public static let folderStepID = "game-folder"
    public static let installerStepID = "installer"

    public var source: Source
    public var title: String
    public var slug: String
    public var recipeID: String
    public var recipeName: String?
    public var publisher: String?
    public var website: String?
    /// The publisher's official installer download, needed to share the recipe.
    public var publicInstallerURL: String?
    public var notes: String?
    public var authors: [String]

    public var runner: RunnerRequirement
    public var graphics: GraphicsBackend
    public var sync: SyncMode
    public var windowsVersion: String
    public var retina: Bool
    public var winetricks: [String]
    public var dllOverrides: [String: String]
    public var env: [String: String]

    /// For `.folder`: the program to launch, relative to the chosen folder.
    /// For the other sources: a Windows path, once known.
    public var launchProgram: String?
    public var launchArgs: [String]
    /// Extra arguments for a silent installer, such as `/S`.
    public var installerArgs: [String]

    public init(
        source: Source,
        title: String,
        slug: String? = nil,
        recipeID: String? = nil,
        runner: RunnerRequirement = RunnerRequirement(family: "any"),
        graphics: GraphicsBackend = .d3dmetal
    ) {
        self.source = source
        self.title = title
        self.slug = slug ?? Self.makeSlug(title)
        self.recipeID = recipeID ?? graphics.rawValue
        self.authors = []
        self.runner = runner
        self.graphics = graphics
        self.sync = RecipeResolver.defaultSync
        self.windowsVersion = RecipeResolver.defaultWindowsVersion
        self.retina = false
        self.winetricks = []
        self.dllOverrides = [:]
        self.env = [:]
        self.launchArgs = []
        self.installerArgs = []
    }

    /// Where a `.folder` game goes on drive C:, such as `C:\Games\Example Game`.
    public var gameFolderWindowsPath: String {
        "C:\\Games\\" + Self.windowsSafeName(title)
    }

    /// The Windows path the recipe launches, or nil if it isn't chosen yet.
    public var launchWindowsPath: String? {
        guard let program = launchProgram, !program.isEmpty else { return nil }
        switch source {
        case .folder: return BottlePath.join(gameFolderWindowsPath, program)
        case .installer, .manual: return program
        }
    }

    public func makeRecipe() -> Recipe {
        var install: [InstallStep] = []
        switch source {
        case .folder(let url):
            install.append(.userFolder(.init(
                id: Self.folderStepID,
                prompt: "Choose your copy of the \(title) folder (the one named \"\(url.lastPathComponent)\" when this recipe was made)",
                to: gameFolderWindowsPath
            )))
        case .installer(let url):
            install += Self.installerSteps(for: url, id: Self.installerStepID, gameTitle: title, args: installerArgs)
        case .manual:
            break
        }

        let prefix = PrefixSpec(
            windows: windowsVersion,
            retina: retina ? true : nil,
            winetricks: winetricks.isEmpty ? nil : winetricks,
            dllOverrides: dllOverrides.isEmpty ? nil : dllOverrides
        )
        return Recipe(
            id: recipeID,
            name: recipeName?.nilIfBlank,
            authors: authors.isEmpty ? nil : authors,
            notes: notes?.nilIfBlank,
            game: GameInfo(
                title: title, slug: slug, publisher: publisher?.nilIfBlank, website: website?.nilIfBlank,
                installer: publicInstallerURL?.nilIfBlank.map { PublicInstaller(url: $0) }
            ),
            stack: StackSpec(runner: runner, graphics: graphics, sync: sync),
            prefix: prefix,
            install: install.isEmpty ? nil : install,
            env: env.isEmpty ? nil : env,
            launch: launchWindowsPath.map { LaunchSpec(exe: $0, args: launchArgs.isEmpty ? nil : launchArgs) }
        )
    }

    /// Steps that ask for an installer and run it. `.msi` packages go through msiexec,
    /// which needs the file on drive C:.
    public static func installerSteps(for installer: URL, id: String, gameTitle: String, args: [String] = []) -> [InstallStep] {
        let fileName = windowsSafeName(installer.lastPathComponent)
        let prompt = "Choose the \(gameTitle) installer (\(installer.lastPathComponent) when this recipe was made)"
        if installer.pathExtension.lowercased() == "msi" {
            let target = "C:\\Installers\\\(fileName)"
            return [
                .userFile(.init(id: id, prompt: prompt, to: target)),
                .runWindows(.init(path: "C:\\windows\\system32\\msiexec.exe", args: ["/i", target] + args, wait: true)),
            ]
        }
        let target = "cache/\(fileName)"
        return [
            .userFile(.init(id: id, prompt: prompt, to: target)),
            .runWindows(.init(path: target, args: args.isEmpty ? nil : args, wait: true)),
        ]
    }

    /// "Example Game: Deluxe!" becomes "example-game-deluxe".
    public static func makeSlug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = folded.lowercased()
            .map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        slug = String(slug.prefix(64))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count < 2 { slug = slug.isEmpty ? "game" : "\(slug)-game" }
        return slug
    }

    /// Removes characters Windows doesn't allow in file names.
    public static func windowsSafeName(_ text: String) -> String {
        let forbidden = Set("<>:\"/\\|?*")
        let cleaned = String(text.map { forbidden.contains($0) || $0.asciiValue.map { $0 < 32 } == true ? "-" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Game" : String(cleaned.prefix(100))
    }

    /// Fills the settings from an inspection, keeping what the player already chose.
    public mutating func apply(_ inspection: GameInspection) {
        graphics = inspection.suggestedGraphics
        // An id that just names the graphics layer follows the new choice.
        if GraphicsBackend(rawValue: recipeID) != nil {
            recipeID = graphics.rawValue
        }
        windowsVersion = inspection.suggestedWindowsVersion
        for verb in inspection.suggestedWinetricks where !winetricks.contains(verb) {
            winetricks.append(verb)
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
