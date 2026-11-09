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
        case .download, .userDownload, .extract, .copy, .runWindows, .userFile, .userFolder: return false
        }
    }

    /// Where the installer is downloaded to in the bottle, and the steps that run it. An MSI
    /// goes to C:\Installers so msiexec can reach it. An installer with a direct link is
    /// downloaded from it; one with only its publisher's page is downloaded by the player from
    /// that page (a `user_download` step), saved as `fileName` (the name of the file the
    /// community check got).
    public static func installerSteps(_ installer: PublicInstaller, sha256: String, signer: String? = nil, fileName: String? = nil, title: String? = nil) throws -> [InstallStep] {
        let name: String
        let fetch: (String) -> InstallStep
        if let link = installer.url {
            guard let url = URL(string: link), url.scheme?.lowercased() == "https" else {
                throw DistillerError.insecureURL(link)
            }
            name = RecipeDraft.windowsSafeName(url.lastPathComponent.isEmpty ? "setup.exe" : url.lastPathComponent)
            fetch = { target in
                .download(signer.map { .init(url: link, signer: $0, to: target) } ?? .init(url: link, sha256: sha256, to: target))
            }
        } else if let page = installer.page {
            guard let url = URL(string: page), url.scheme?.lowercased() == "https" else {
                throw DistillerError.insecureURL(page)
            }
            let given = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            name = RecipeDraft.windowsSafeName(given.isEmpty ? "setup.exe" : given)
            let prompt = "Download \(title.map { "\($0)'s" } ?? "the game's") installer from its publisher's download page."
            fetch = { target in
                .userDownload(.init(id: installerDownloadID, prompt: prompt, page: page,
                                    sha256: signer == nil ? sha256 : nil, signer: signer, to: target))
            }
        } else {
            throw DistillerError.invalidRecipe("game.installer needs its download link (url) or its download page (page).")
        }
        let args = installer.args ?? []
        if (name as NSString).pathExtension.lowercased() == "msi" {
            let target = "C:\\Installers\\\(name)"
            return [
                fetch(target),
                .runWindows(.init(path: "C:\\windows\\system32\\msiexec.exe", args: ["/i", target] + args, wait: true)),
            ]
        }
        let target = "cache/\(name)"
        return [
            fetch(target),
            .runWindows(.init(path: target, args: args.isEmpty ? nil : args, wait: true)),
        ]
    }

    /// The id of the `user_download` step for an installer from a download page.
    public static let installerDownloadID = "installer"

    /// The shareable recipe: the player's settings, installed from the public installer, and
    /// launching `launchExe` (found after the installer ran). Throws without `game.installer`.
    /// `installerSigner`, for an installer that `updates`, verifies it by its publisher's
    /// signature instead of `installerSHA256` (and raises the recipe to schema 2).
    /// `installerFileName` names the installer the check got from the download page, for an
    /// installer with only a page.
    public static func shareableRecipe(from recipe: Recipe, installerSHA256: String, installerSigner: String? = nil, installerFileName: String? = nil, launchExe: String?) throws -> Recipe {
        guard let installer = recipe.game.installer else {
            throw DistillerError.invalidRecipe("it has no official public installer (game.installer: its download link or page).")
        }
        var shared = recipe
        // Settings first, so runtimes and registry values are in place before the installer
        // runs; the installer last, since it may start a launcher or the game and keep running.
        shared.install = (recipe.install ?? []).filter(isKeptStep) + (try installerSteps(installer, sha256: installerSHA256, signer: installerSigner, fileName: installerFileName, title: recipe.game.title))
        shared.schema = max(shared.schema, shared.requiredSchema)
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
