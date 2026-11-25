import Foundation

/// The launchers Distiller knows: programs that install and start games of their own in the
/// bottle they're in. A library entry whose program is a launcher's client is that launcher;
/// the games it installs get entries of their own beneath it, sharing its bottle
/// (`DistillerEngine.syncLauncherGames`).
public enum LauncherKind: String, Codable, CaseIterable, Sendable {
    case steam
    case battlenet

    public var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .battlenet: return "Battle.net"
        }
    }

    /// Whether a launch path is this launcher's client.
    public func isClient(_ exe: String) -> Bool {
        let path = exe.replacingOccurrences(of: "/", with: "\\").lowercased()
        switch self {
        case .steam: return path.hasSuffix("\\steam\\steam.exe")
        case .battlenet: return path.hasSuffix("\\battle.net\\battle.net launcher.exe") || path.hasSuffix("\\battle.net\\battle.net.exe")
        }
    }

    /// The launcher whose client `exe` is, if any.
    public static func kind(ofClient exe: String) -> LauncherKind? {
        allCases.first { $0.isClient(exe) }
    }
}

/// Which launcher's game a library entry is.
public struct LauncherLink: Codable, Equatable, Sendable, Hashable {
    public var kind: LauncherKind
    /// The launcher's id for the game: a Steam app ID ("440"), a Battle.net product ("wow").
    public var gameID: String
    /// The library entry of the launcher (whose bottle this game shares).
    public var launcherID: String
    /// The game's own program (Windows path), for its icon.
    public var program: String?

    enum CodingKeys: String, CodingKey {
        case kind, program
        case gameID = "game_id"
        case launcherID = "launcher_id"
    }

    public init(kind: LauncherKind, gameID: String, launcherID: String, program: String?) {
        self.kind = kind
        self.gameID = gameID
        self.launcherID = launcherID
        self.program = program
    }
}

/// A game a launcher has installed in its bottle.
public struct LauncherGame: Equatable, Sendable {
    public var gameID: String
    public var name: String
    /// Its folder, on the Mac.
    public var folder: URL
    /// The program to take its icon from, when known (else Distiller picks one in the folder).
    public var iconProgram: URL?
}
