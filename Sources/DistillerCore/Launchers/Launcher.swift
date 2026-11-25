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
    /// The game's folder (Windows path, ending in `\`), when it isn't the program's.
    public var folder: String?

    enum CodingKeys: String, CodingKey {
        case kind, program, folder
        case gameID = "game_id"
        case launcherID = "launcher_id"
    }

    public init(kind: LauncherKind, gameID: String, launcherID: String, program: String?, folder: String? = nil) {
        self.kind = kind
        self.gameID = gameID
        self.launcherID = launcherID
        self.program = program
        self.folder = folder
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

/// How the player wants a launcher started on this Mac (Steam for now): its view, and the
/// Friends status to set once it's up. Applied whenever Distiller starts the launcher, whether
/// for itself or for one of its games.
public struct LauncherOptions: Codable, Equatable, Hashable, Sendable {
    public enum StartView: String, Codable, CaseIterable, Sendable {
        case normal
        case bigPicture = "big_picture"
        /// Read so earlier choices still load, offered no more, and treated as "as Steam left
        /// it": Steam under Wine on a Mac ignores `-silent` (no tray to start in) and doesn't
        /// switch to Small Mode for `steam://open/minigameslist`; it opens its full window once
        /// signed in, whatever view it remembers.
        case small
        case menuBar = "menu_bar"

        /// The views that work.
        public static let offered: [StartView] = [.normal, .bigPicture]

        public var displayName: String {
            switch self {
            case .normal: return "Normal window"
            case .bigPicture: return "Big Picture"
            case .small: return "Small Mode"
            case .menuBar: return "Menu bar only"
            }
        }
    }

    public enum FriendsStatus: String, Codable, CaseIterable, Sendable {
        case online, away, invisible, offline

        public var displayName: String {
            switch self {
            case .online: return "Online"
            case .away: return "Away"
            case .invisible: return "Invisible"
            case .offline: return "Signed out of Friends"
            }
        }
    }

    /// Nil: as the launcher last left it.
    public var startView: StartView?
    /// Nil: leave it as it is.
    public var friends: FriendsStatus?

    enum CodingKeys: String, CodingKey {
        case friends
        case startView = "start_view"
    }

    public init(startView: StartView? = nil, friends: FriendsStatus? = nil) {
        self.startView = startView
        self.friends = friends
    }

    public var isEmpty: Bool { startView == nil && friends == nil }

    /// Steam's start-up options for the view.
    public var steamStartArguments: [String] {
        switch startView {
        case .normal?: return ["-nobigpicture"]
        case .bigPicture?: return ["-gamepadui"]
        case .small?, .menuBar?, nil: return []
        }
    }

    /// The Friends status isn't a link: Steam's `steam://friends/status/offline` doesn't sign
    /// out of Friends, so it's written into Steam's own saved status before it starts.
    /// Steam's number for the Friends status (`ePersonaState`, as it saves it).
    public var steamPersonaState: Int? {
        switch friends {
        case .offline?: return 0
        case .online?: return 1
        case .away?: return 3
        case .invisible?: return 7
        case nil: return nil
        }
    }
}
