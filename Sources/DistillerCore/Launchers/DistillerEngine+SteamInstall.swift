import Foundation

/// What adding a Steam game's recipe did.
public enum SteamGameInstall: Equatable, Sendable {
    /// Steam already has the game: its entry (under Steam) now has the recipe's own options.
    case alreadyInstalled(Game)
    /// Steam was asked to install it (it shows its install dialog). The entry appears under Steam
    /// once Steam has finished, with the recipe's own options.
    case requested(appID: String, launcher: Game)
}

extension SteamLibrary {
    /// The Steam app ID when `recipe` is a Steam game's (it starts Steam's client with
    /// `-applaunch <id>`), else nil. Such a recipe has nothing to install into a bottle of its
    /// own: Steam installs the game into the bottle it shares with its games.
    public static func gameAppID(in recipe: Recipe) -> String? {
        guard let launch = recipe.launch, isClient(launch.exe), let args = launch.args,
              let index = args.firstIndex(of: "-applaunch"), index + 1 < args.count else { return nil }
        let id = args[index + 1]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }
}

extension DistillerEngine {
    /// Adds a Steam game's recipe: in the bottle Steam is already in (never a bottle of its
    /// own). If Steam has the game, its entry gets the recipe's own options (launch options,
    /// notes, name) at once; otherwise Steam is asked to install it (`steam://install/<id>`),
    /// and the options are kept (`DistillerPaths.pendingSteamGames`) until it appears.
    /// `request` starts the install in Steam (tests replace it).
    public func installSteamGame(
        _ recipe: Recipe,
        request: ((_ launcher: Game, _ clientExe: String, _ appID: String) throws -> Void)? = nil
    ) throws -> SteamGameInstall {
        guard let appID = SteamLibrary.gameAppID(in: recipe) else {
            throw DistillerError.invalidRecipe("\(recipe.game.title)'s recipe doesn't start a Steam game.")
        }
        let launchers = steamLaunchers()
        guard let launcher = launchers.first(where: { $0.recipe.stack.runner.family == recipe.stack.runner.family }) ?? launchers.first,
              let clientExe = resolve(launcher.recipe, overrides: launcher.overrides).launch?.exe else {
            throw DistillerError.setupFailed(
                "\(recipe.game.title) is a Steam game: its recipe starts it through Steam, which installs it next to itself. Add Steam to your library first (its recipe, such as steam.yaml), then add \(recipe.game.title) again."
            )
        }
        try savePendingSteamGame(recipe, appID: appID, launcherID: launcher.id)
        syncSteamGames()
        if let game = library.load().first(where: { $0.steam?.launcherID == launcher.id && $0.steam?.appID == appID }) {
            return .alreadyInstalled(game)
        }
        if let request {
            try request(launcher, clientExe, appID)
        } else {
            _ = try run(program: clientExe, arguments: ["steam://install/\(appID)"], inBottle: launcher.bottleID)
        }
        return .requested(appID: appID, launcher: launcher)
    }

    func pendingSteamGameURL(appID: String, launcherID: String) -> URL {
        paths.pendingSteamGames.appendingPathComponent("\(launcherID)-\(appID).yaml")
    }

    func savePendingSteamGame(_ recipe: Recipe, appID: String, launcherID: String) throws {
        try FileManager.default.createDirectory(at: paths.pendingSteamGames, withIntermediateDirectories: true)
        try RecipeLoader.encode(recipe).write(to: pendingSteamGameURL(appID: appID, launcherID: launcherID), atomically: true, encoding: .utf8)
    }

    /// The recipe added for a game Steam hadn't installed yet, taken (removed) when its entry
    /// is made.
    func takePendingSteamGame(appID: String, launcherID: String) -> Recipe? {
        let url = pendingSteamGameURL(appID: appID, launcherID: launcherID)
        guard let recipe = try? RecipeLoader.load(from: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return recipe
    }

    /// A Steam game's entry recipe with the added recipe's own options: its launch options
    /// (after Steam's), notes and name. Bottle settings stay Steam's.
    static func applying(_ added: Recipe, to recipe: Recipe, appID: String) -> Recipe {
        var result = recipe
        result.launch?.args = steamLaunchArguments(appID: appID, recipeArgs: added.launch?.args)
        result.notes = added.notes ?? result.notes
        result.name = added.name ?? result.name
        result.authors = added.authors ?? result.authors
        return result
    }
}
