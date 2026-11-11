import Foundation

/// Removes component versions nothing needs any more, after an update.
///
/// A version is removable when it isn't the active version of its component, Distiller can
/// download it again (its source is an https address: imported components, such as D3DMetal
/// from the player's own download, are never removed automatically), and, for a Wine build,
/// every bottle can still be opened by another installed build (`DistillerEngine.wine(_:canOpen:madeBy:)`).
/// Removing a version also removes what was made from it: composed Wine + graphics builds and,
/// for a Wine build, its template prefix. Anything a running program uses is left alone.
public enum ComponentCleanup {
    /// The versions that `remove` would take away, given the installed components, the
    /// player's active choices and the bottles.
    static func removable(installed: [InstalledComponent], chosen: [String: String], bottles: [Bottle]) -> [InstalledComponent] {
        let active = Set(ComponentStore.active(in: installed, chosen: chosen).map(\.id))
        var remaining = installed
        var result: [InstalledComponent] = []
        // Oldest first, so the newest of the unneeded versions is the last to go.
        let candidates = installed
            .filter { !active.contains($0.id) && isRedownloadable($0) }
            .sorted { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
        for candidate in candidates {
            let without = remaining.filter { $0.id != candidate.id }
            if candidate.manifest.kind == .wine {
                let stillOpenable = bottles.allSatisfy { bottle in
                    let made = BottleWine(bottle.wine)
                    let original = installed.first { $0.manifest.kind == .wine && $0.manifest.id == made.id }
                    let usedBefore = remaining.contains { $0.manifest.kind == .wine && DistillerEngine.wine($0, canOpen: bottle, madeBy: original) }
                    // A bottle no installed build can open already needs another Wine; removing
                    // this one doesn't change that.
                    guard usedBefore else { return true }
                    return without.contains { $0.manifest.kind == .wine && DistillerEngine.wine($0, canOpen: bottle, madeBy: original) }
                }
                guard stillOpenable else { continue }
            }
            remaining = without
            result.append(candidate)
        }
        return result
    }

    static func isRedownloadable(_ component: InstalledComponent) -> Bool {
        component.manifest.source?.lowercased().hasPrefix("https://") == true
    }

    /// Whether any running process's command line mentions `directory` (a Wine build's
    /// `wine`/`wineserver` run from inside it).
    static func isInUse(_ directory: URL, commands: [String]) -> Bool {
        let path = directory.standardizedFileURL.path
        return commands.contains { $0.contains(path + "/") }
    }
}

extension DistillerEngine {
    /// The component versions `removeUnusedComponents` would remove now.
    public func unusedComponents() -> [InstalledComponent] {
        ComponentCleanup.removable(
            installed: components.installed(), chosen: components.chosenActiveVersions(), bottles: bottles.list()
        )
    }

    /// Removes unused component versions (`ComponentCleanup`), with the composed builds and
    /// template made from them, and returns what it removed. Skips anything in use.
    @discardableResult
    public func removeUnusedComponents() async -> [InstalledComponent] {
        let unused = unusedComponents()
        guard !unused.isEmpty else { return [] }
        let commands = await Self.runningCommands()
        let composed = components.composed()
        var removed: [InstalledComponent] = []
        for component in unused {
            let derived = composed.filter { $0.manifest.composedFrom?.contains(component.id) == true }
            let template = component.manifest.kind == .wine
                ? paths.templates.appendingPathComponent("\(component.manifest.id)-\(component.manifest.version)", isDirectory: true)
                : nil
            let folders = [component.directory] + derived.map(\.directory)
            guard !folders.contains(where: { ComponentCleanup.isInUse($0, commands: commands) }) else { continue }
            for folder in derived.map(\.directory) + [template].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: folder)
            }
            do {
                try FileManager.default.removeItem(at: component.directory)
                removed.append(component)
            } catch {
                continue
            }
        }
        return removed
    }

    static func runningCommands() async -> [String] {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axww", "-o", "command="]) else {
            return []
        }
        return result.output.components(separatedBy: "\n")
    }
}
