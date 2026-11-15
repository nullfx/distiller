import Foundation

/// Valve's KeyValues text format (VDF), as Steam writes its library files: quoted keys, each
/// followed by a quoted value or a `{ … }` block; `//` comments. Read-only and lenient about
/// whitespace; anything else is refused. Keys compare without case, as Steam treats them.
public indirect enum VDFValue: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDFValue)])

    public static func == (lhs: VDFValue, rhs: VDFValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public subscript(key: String) -> VDFValue? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var entries: [(key: String, value: VDFValue)] {
        if case .object(let entries) = self { return entries }
        return []
    }

    /// Parses a whole file: one or more top-level `"key" { … }` entries, as an object.
    public static func parse(_ text: String) -> VDFValue? {
        var scanner = Scanner(Array(text.unicodeScalars))
        guard let entries = scanner.entries(topLevel: true) else { return nil }
        return .object(entries)
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0
        var depth = 0
        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func skip() {
            while index < scalars.count {
                let c = scalars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1; continue }
                if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                return
            }
        }

        mutating func quoted() -> String? {
            guard index < scalars.count, scalars[index] == "\"" else { return nil }
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { return String(result) }
                if c == "\\", index < scalars.count {
                    let next = scalars[index]
                    index += 1
                    switch next {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(next)       // \\ and \"
                    }
                    continue
                }
                result.append(c)
            }
            return nil
        }

        mutating func entries(topLevel: Bool) -> [(key: String, value: VDFValue)]? {
            var result: [(key: String, value: VDFValue)] = []
            while true {
                skip()
                if index >= scalars.count { return topLevel ? result : nil }
                if scalars[index] == "}" {
                    guard !topLevel else { return nil }
                    index += 1
                    return result
                }
                guard let key = quoted() else { return nil }
                skip()
                guard index < scalars.count else { return nil }
                if scalars[index] == "{" {
                    index += 1
                    depth += 1
                    guard depth <= 32, let children = entries(topLevel: false) else { return nil }
                    depth -= 1
                    result.append((key, .object(children)))
                } else {
                    guard let value = quoted() else { return nil }
                    result.append((key, .string(value)))
                }
            }
        }
    }
}

/// A game Steam has installed in a bottle, from its app manifest (`appmanifest_<id>.acf`).
public struct SteamApp: Equatable, Sendable {
    public var appID: String
    public var name: String
    /// Its folder under `steamapps\common`, as a Windows path.
    public var installFolder: String
    public var fullyInstalled: Bool
    /// Download progress, when Steam is installing or updating it.
    public var bytesDownloaded: Int64?
    public var bytesToDownload: Int64?
}

/// Reading what Steam has installed in a bottle. Steam keeps a manifest per app in each library
/// folder's `steamapps`, listed in `steamapps\libraryfolders.vdf`; a manifest's `StateFlags`
/// has bit 4 set once the app is fully installed (1026 while downloading).
public enum SteamLibrary {
    /// Where Steam's client is in a bottle, as the recipe names it.
    public static let clientPath = #"C:\Program Files (x86)\Steam\steam.exe"#

    /// Apps Steam installs that aren't games (its shared redistributables).
    static let notGames: Set<String> = ["228980"]

    /// Whether a launch path is Steam's client.
    public static func isClient(_ exe: String) -> Bool {
        let normalized = exe.replacingOccurrences(of: "/", with: "\\").lowercased()
        return normalized.hasSuffix("\\steam\\steam.exe")
    }

    /// The Steam folder (holding steam.exe) of a bottle, from the client's launch path.
    static func steamFolder(clientExe: String, root: URL) -> URL? {
        (try? BottlePath.resolve(clientExe, in: root))?.deletingLastPathComponent()
    }

    /// The `steamapps` folders of every library on the bottle's C: drive.
    static func libraryFolders(steamFolder: URL, root: URL) -> [URL] {
        var folders = [steamFolder.appendingPathComponent("steamapps", isDirectory: true)]
        let listing = steamFolder.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: listing, encoding: .utf8), let vdf = VDFValue.parse(text) {
            for (_, library) in vdf["libraryfolders"]?.entries ?? [] {
                guard let path = library["path"]?.string,
                      let folder = try? BottlePath.resolve(path, in: root) else { continue }      // other drives: not yet
                let steamapps = folder.appendingPathComponent("steamapps", isDirectory: true)
                if !folders.contains(where: { $0.standardizedFileURL == steamapps.standardizedFileURL }) { folders.append(steamapps) }
            }
        }
        return folders
    }

    /// Parses one app manifest.
    public static func app(fromManifest text: String) -> SteamApp? {
        guard let state = VDFValue.parse(text)?["AppState"],
              let appID = state["appid"]?.string, appID.allSatisfy(\.isNumber), !appID.isEmpty,
              let name = state["name"]?.string, let folder = state["installdir"]?.string,
              !folder.contains("/"), !folder.contains("\\"), folder != "..", folder != "." else { return nil }
        let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
        return SteamApp(
            appID: appID, name: name, installFolder: folder, fullyInstalled: flags & 4 != 0,
            bytesDownloaded: state["BytesDownloaded"]?.string.flatMap { Int64($0) },
            bytesToDownload: state["BytesToDownload"]?.string.flatMap { Int64($0) }
        )
    }

    /// The games Steam has fully installed in a bottle, with the host folder of each.
    public static func installedGames(clientExe: String, root: URL) -> [(app: SteamApp, folder: URL)] {
        guard let steam = steamFolder(clientExe: clientExe, root: root) else { return [] }
        var result: [(app: SteamApp, folder: URL)] = []
        for steamapps in libraryFolders(steamFolder: steam, root: root) {
            let manifests = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8), let app = app(fromManifest: text),
                      app.fullyInstalled, !notGames.contains(app.appID),
                      !result.contains(where: { $0.app.appID == app.appID }) else { continue }
                let folder = steamapps.appendingPathComponent("common", isDirectory: true).appendingPathComponent(app.installFolder, isDirectory: true)
                result.append((app, folder))
            }
        }
        return result.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    /// Whether Steam's log says `appID` is running: the last thing it logged about the app was
    /// starting a process for it (`gameprocess_log.txt`), and the PID it gave the game.
    public static func runningState(appID: String, log text: String) -> (running: Bool, pid: Int?) {
        var running = false
        var pid: Int?
        // Steam writes Windows line endings, and Swift treats "\r\n" as one Character, so
        // split on any newline rather than on "\n".
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("AppID \(appID) adding PID ") {
                running = true
                pid = line.components(separatedBy: "adding PID ").last?.split(separator: " ").first.flatMap { Int($0) }
            } else if line.contains("Remove \(appID) from running list") {
                running = false
                pid = nil
            }
        }
        return (running, pid)
    }
}
