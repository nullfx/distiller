import CryptoKit
import Foundation

/// Turns a player's recipe into the shareable one: installed from the publisher's public
/// installer instead of files on the player's Mac. `DistillerEngine.runCommunityCheck`
/// proves that recipe works before it can be submitted.
public enum CommunityCheck {
    /// Install steps that only make sense on the player's Mac (their files and folders, and
    /// installers run from them) are replaced; settings steps are kept.
    static func isKeptStep(_ step: InstallStep) -> Bool {
        switch step {
        case .winetricks, .registry, .dllOverride: return true
        case .download, .extract, .copy, .runWindows, .userFile, .userFolder: return false
        }
    }

    /// Where the installer is downloaded to in the bottle, and the steps that run it. An MSI
    /// goes to C:\Installers so msiexec can reach it.
    public static func installerSteps(_ installer: PublicInstaller, sha256: String) throws -> [InstallStep] {
        guard let url = URL(string: installer.url), url.scheme?.lowercased() == "https" else {
            throw DistillerError.insecureURL(installer.url)
        }
        let name = RecipeDraft.windowsSafeName(url.lastPathComponent.isEmpty ? "setup.exe" : url.lastPathComponent)
        let args = installer.args ?? []
        if url.pathExtension.lowercased() == "msi" {
            let target = "C:\\Installers\\\(name)"
            return [
                .download(.init(url: installer.url, sha256: sha256, to: target)),
                .runWindows(.init(path: "C:\\windows\\system32\\msiexec.exe", args: ["/i", target] + args, wait: true)),
            ]
        }
        let target = "cache/\(name)"
        return [
            .download(.init(url: installer.url, sha256: sha256, to: target)),
            .runWindows(.init(path: target, args: args.isEmpty ? nil : args, wait: true)),
        ]
    }

    /// The shareable recipe: the player's settings, installed from the public installer, and
    /// launching `launchExe` (found after the installer ran). Throws without `game.installer`.
    public static func shareableRecipe(from recipe: Recipe, installerSHA256: String, launchExe: String?) throws -> Recipe {
        guard let installer = recipe.game.installer else {
            throw DistillerError.invalidRecipe("it has no official public installer (game.installer.url).")
        }
        var shared = recipe
        // Settings first, so runtimes and registry values are in place before the installer
        // runs; the installer last, since it may start a launcher or the game and keep running.
        shared.install = (recipe.install ?? []).filter(isKeptStep) + (try installerSteps(installer, sha256: installerSHA256))
        if let launchExe {
            shared.launch = LaunchSpec(exe: launchExe, args: recipe.launch?.args, workingDir: nil)
        } else {
            shared.launch = nil
        }
        return shared
    }

    /// Identifies a recipe's content, ignoring what doesn't change how it installs or runs
    /// (notes, name, authors, where it was forked from).
    public static func fingerprint(_ recipe: Recipe) -> String {
        var stripped = recipe
        stripped.notes = nil
        stripped.name = nil
        stripped.authors = nil
        stripped.forkedFrom = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stripped)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `game` has a passing check that still matches its recipe.
    public static func isCurrent(_ game: Game) -> Bool {
        guard let check = game.communityCheck else { return false }
        return check.sourceFingerprint == fingerprint(game.recipe)
    }

    /// What to submit: the checked recipe, with the player's current notes and name.
    public static func recipeToSubmit(for game: Game) -> Recipe? {
        guard isCurrent(game), var recipe = game.communityCheck?.recipe else { return nil }
        recipe.notes = game.recipe.notes
        recipe.name = game.recipe.name
        return recipe
    }
}
