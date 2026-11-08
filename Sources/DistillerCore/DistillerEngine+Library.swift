import Foundation

/// Whether a game in the library can be played right now.
public enum GameAvailability: Equatable, Sendable {
    case ready
    /// No program to launch has been chosen yet.
    case needsSetup
    /// Something it needs is missing, such as a disconnected drive. The text says what.
    case unavailable(String)

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Availability and icons for games in the library.
extension DistillerEngine {
    /// Checks the game's storage, bottle and program without starting anything. Cheap enough
    /// to run for every game whenever the library is shown or a drive comes or goes.
    public func availability(of game: Game) -> GameAvailability {
        if let missing = paths.unavailable.first {
            return .unavailable(missing.message)
        }
        guard let bottle = try? bottles.bottle(id: game.bottleID) else {
            return .unavailable("Its bottle (\(game.bottleID)) is missing from \(paths.bottles.path).")
        }
        let resolved = resolve(game.recipe, overrides: game.overrides)
        guard let exe = resolved.launch?.exe else { return .needsSetup }
        guard let link = try? BottlePath.resolve(exe, in: bottles.root(of: bottle)) else {
            return .unavailable("Its launch path \(exe) isn't valid.")
        }
        let program = link.followingSymlinks
        if FileManager.default.fileExists(atPath: program.path) {
            // Last, because a missing drive or folder is the more useful thing to say.
            do {
                _ = try chooseWine(for: resolved, bottle: bottle)
                return .ready
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }
        if let drive = StorageVolume.volumeName(inVolumesPath: program), !FileManager.default.fileExists(atPath: "/Volumes/\(drive)") {
            return .unavailable("It's on “\(drive)”, which isn't connected. Connect the drive to play.")
        }
        if program.path != link.path {
            return .unavailable("Its folder \(program.deletingLastPathComponent().path) can't be found. It may have been moved or renamed.")
        }
        return .unavailable("Its program \(exe) is missing from the bottle.")
    }

    // MARK: Icons

    private func extractedIconURL(for game: Game) -> URL { paths.icons.appendingPathComponent("\(game.id).png") }
    private func customIconURL(for game: Game) -> URL { paths.icons.appendingPathComponent("\(game.id)-custom.png") }

    /// The icon to show: one the player chose, else the one read from the game's program.
    public func iconURL(for game: Game) -> URL? {
        [customIconURL(for: game), extractedIconURL(for: game)].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func hasCustomIcon(_ game: Game) -> Bool {
        FileManager.default.fileExists(atPath: customIconURL(for: game).path)
    }

    /// Reads the icon from the game's launch program and saves it. Returns nil when the program
    /// can't be reached (for example, its drive is disconnected) or has no icon; an icon
    /// saved earlier is kept in that case.
    @discardableResult
    public func refreshIcon(for game: Game) -> URL? {
        // Needs only the program file, not a Wine build that can run it.
        guard paths.unavailable.isEmpty,
              let bottle = try? bottles.bottle(id: game.bottleID),
              let exe = resolve(game.recipe, overrides: game.overrides).launch?.exe,
              let program = try? BottlePath.resolve(exe, in: bottles.root(of: bottle)).followingSymlinks,
              let ico = PEIcon.ico(fromExecutable: program),
              let png = PEIcon.png(fromImageData: ico) else { return nil }
        let url = extractedIconURL(for: game)
        do {
            try FileManager.default.createDirectory(at: paths.icons, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Uses an image (PNG, JPEG, .icns, .ico, …) or another program's icon (.exe) for the game.
    public func setCustomIcon(for game: Game, from source: URL) throws {
        let data = try Data(contentsOf: source)
        let imageData = source.pathExtension.lowercased() == "exe" ? PEIcon.ico(fromExecutableData: data) : data
        guard let imageData, let png = PEIcon.png(fromImageData: imageData) else {
            throw DistillerError.invalidRecipe("no icon or image could be read from \(source.lastPathComponent).")
        }
        try FileManager.default.createDirectory(at: paths.icons, withIntermediateDirectories: true)
        try png.write(to: customIconURL(for: game), options: .atomic)
    }

    /// Goes back to the icon read from the game's program.
    public func removeCustomIcon(for game: Game) throws {
        let url = customIconURL(for: game)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Removes the game's icons, for when it leaves the library.
    public func removeIcons(for game: Game) {
        try? FileManager.default.removeItem(at: extractedIconURL(for: game))
        try? FileManager.default.removeItem(at: customIconURL(for: game))
        try? FileManager.default.removeItem(at: communityMediaFolder(for: game))
    }

    // MARK: Community check pictures

    func communityMediaFolder(for game: Game) -> URL {
        paths.communityMedia.appendingPathComponent(game.id, isDirectory: true)
    }

    /// The icon saved by the game's last passing community check, if it saved one.
    public func communityCheckIcon(for game: Game) -> URL? {
        guard game.communityCheck?.hasIcon == true else { return nil }
        let url = communityMediaFolder(for: game).appendingPathComponent(CommunityMedia.iconFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every screenshot captured during the game's last passing community check, in order.
    public func communityCheckCaptures(for game: Game) -> [(name: String, url: URL)] {
        let folder = communityMediaFolder(for: game)
        return (game.communityCheck?.captures ?? []).compactMap { name in
            guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? (name, url) : nil
        }
    }

    /// The captures the player chose to share, cover first.
    public func sharedCommunityScreenshots(for game: Game) -> [URL] {
        let captures = communityCheckCaptures(for: game)
        return (game.communityCheck?.sharedCaptures ?? []).compactMap { name in captures.first { $0.name == name }?.url }
    }

    /// Chooses which captures to share and in what order (the first is the cover). Unknown
    /// names are dropped and at most `CommunityMedia.maxSharedScreenshots` are kept.
    @discardableResult
    public func setSharedScreenshots(_ names: [String], for game: Game) throws -> Game {
        var updated = (try? library.game(id: game.id)) ?? game
        guard var check = updated.communityCheck else { return updated }
        let known = Set(check.captures ?? [])
        var chosen: [String] = []
        for name in names where known.contains(name) && !chosen.contains(name) { chosen.append(name) }
        check.sharedCaptures = Array(chosen.prefix(CommunityMedia.maxSharedScreenshots))
        updated.communityCheck = check
        try library.upsert(updated)
        return updated
    }
}
