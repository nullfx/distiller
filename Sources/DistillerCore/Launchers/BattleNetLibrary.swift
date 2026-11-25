import Foundation

/// Reading what Battle.net has installed in a bottle. Its Agent keeps a summary of installed
/// games in `C:\ProgramData\Battle.net\Agent\aggregate.json` (`installed`: name, `product_id`
/// such as "wow" or "d3", and `icon_path`, the game's own launcher program). A game is listed
/// as soon as it starts downloading; Blizzard games can be played before they've finished,
/// once their program is there, which is when Distiller lists them too.
public enum BattleNetLibrary {
    /// Where Battle.net's launcher is in a bottle, as its recipe names it.
    public static let clientPath = #"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#

    static let summaryPath = #"C:\ProgramData\Battle.net\Agent\aggregate.json"#
    static let databasePath = #"C:\ProgramData\Battle.net\Agent\product.db"#
    /// Battle.net's own products in its database, not games.
    static let notGames: Set<String> = ["agent", "bna", "battle.net"]

    struct Summary: Decodable {
        struct Product: Decodable {
            var name: String
            var productID: String
            var iconPath: String?

            enum CodingKeys: String, CodingKey {
                case name
                case productID = "product_id"
                case iconPath = "icon_path"
            }
        }

        var installed: [Product]
    }

    /// The program that starts a game: Battle.net itself, next to its launcher
    /// (`Battle.net.exe --exec="launch <code>"`).
    public static func gameClient(launcherExe: String) -> String {
        let normalized = launcherExe.replacingOccurrences(of: "/", with: "\\")
        guard let slash = normalized.lastIndex(of: "\\") else { return normalized }
        return String(normalized[...slash]) + "Battle.net.exe"
    }

    /// The codes Battle.net's `--exec="launch <code>"` takes for its products, where they
    /// differ from the product id.
    static let launchCodes: [String: String] = [
        "wow": "WoW", "wow_classic": "WoW_wow_classic", "wow_classic_era": "WoW_wow_classic_era",
        "d3": "D3", "pro": "Pro", "s1": "S1", "s2": "S2", "w3": "W3", "hs": "WTCG", "wtcg": "WTCG",
        "hero": "Hero", "osi": "OSI", "fen": "Fen", "rtro": "RTRO", "anbs": "ANBS",
    ]

    public static func launchCode(for productID: String) -> String {
        launchCodes[productID.lowercased()] ?? productID
    }

    /// The games Battle.net has installed in a bottle whose program is there, by name: the
    /// install database (`product.db`) lists every one with its folder; the Agent's summary
    /// (`aggregate.json`) adds names and icon programs, but only for Blizzard's own games
    /// (Call of Duty isn't in it). A game the summary doesn't name is named after its folder,
    /// and its icon comes from its likeliest program.
    public static func installedGames(root: URL) -> [LauncherGame] {
        var games = summaryGames(root: root)
        guard let databaseFile = try? BottlePath.resolve(databasePath, in: root),
              let data = try? Data(contentsOf: databaseFile) else { return games }
        for install in ProductDatabase.installs(in: data) {
            let code = install.productCode
            guard !notGames.contains(code.lowercased()), !notGames.contains(install.uid.lowercased()),
                  code.range(of: "^[A-Za-z0-9_]{1,40}$", options: .regularExpression) != nil,
                  !games.contains(where: { $0.gameID.caseInsensitiveCompare(code) == .orderedSame
                      || $0.folder.standardizedFileURL == ((try? BottlePath.resolve(install.installPath.replacingOccurrences(of: "/", with: "\\"), in: root))?.standardizedFileURL) }),
                  let folder = try? BottlePath.resolve(install.installPath.replacingOccurrences(of: "/", with: "\\"), in: root),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            games.append(LauncherGame(gameID: code, name: folder.lastPathComponent, folder: folder, iconProgram: nil))
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func summaryGames(root: URL) -> [LauncherGame] {
        guard let summaryFile = try? BottlePath.resolve(summaryPath, in: root),
              let data = try? Data(contentsOf: summaryFile),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return [] }
        var games: [LauncherGame] = []
        for product in summary.installed {
            guard product.productID.range(of: "^[A-Za-z0-9_]{1,40}$", options: .regularExpression) != nil,
                  !games.contains(where: { $0.gameID == product.productID }),
                  let iconPath = product.iconPath,
                  let program = try? BottlePath.resolve(iconPath.replacingOccurrences(of: "/", with: "\\"), in: root),
                  FileManager.default.fileExists(atPath: program.path) else { continue }
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            games.append(LauncherGame(gameID: product.productID, name: name.isEmpty ? product.productID : name,
                                      folder: program.deletingLastPathComponent(), iconProgram: program))
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Windows programs running from a game's folder (`C:\…\World of Warcraft\`), by name,
    /// from the bottle's process list (Wine shows each program's Windows path). The game's own
    /// small launcher program, which only hands over to Battle.net, doesn't count.
    public static func runningPrograms(inFolder folder: String, commands: [String]) -> [String] {
        let prefix = folder.lowercased().hasSuffix("\\") ? folder.lowercased() : folder.lowercased() + "\\"
        var names: [String] = []
        for command in commands {
            let lowered = command.lowercased()
            guard lowered.hasPrefix(prefix), let exe = lowered.range(of: ".exe") else { continue }
            let path = String(command[command.startIndex..<command.index(command.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: exe.upperBound))])
            let name = String(path.split(separator: "\\").last ?? "")
            if name.lowercased().hasSuffix(" launcher.exe") || names.contains(name) { continue }
            names.append(name)
        }
        return names
    }
}
