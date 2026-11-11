import Foundation

/// How Distiller keeps Wine builds, graphics layers and winetricks up to date
/// (`settings.json` `component_updates`). Checking by hand works in every mode.
public enum ComponentUpdateMode: String, Codable, CaseIterable, Sendable {
    /// Check once a day and show what's new; install only when the player says so.
    case ask
    /// Check once a day and install updates by themselves.
    case auto
    /// Never check by itself; keep components as they are.
    case off

    public var displayName: String {
        switch self {
        case .ask: return "Check, and ask before installing"
        case .auto: return "Install updates automatically"
        case .off: return "Don't check; keep components as they are"
        }
    }
}

/// A newer release of an installed component.
public struct ComponentUpdate: Identifiable, Hashable, Sendable {
    public enum Release: Hashable, Sendable {
        case wine(WineRelease)
        case graphics(GraphicsLayerRelease)
        case winetricks(version: String)
    }

    /// The component id, such as "wine-staging".
    public var id: String
    public var kind: ComponentKind
    public var displayName: String
    /// The newest installed version.
    public var installedVersion: String
    public var availableVersion: String
    public var release: Release
    /// The older version the player chose to keep active, if any. Automatic updates skip a
    /// held component; installing it by hand makes the new version active.
    public var heldVersion: String?

    /// The download size, when the source says.
    public var size: Int64? {
        switch release {
        case .wine(let release): return release.size
        case .graphics(let release): return release.size
        case .winetricks: return nil
        }
    }
}

/// The result of a check: updates found, and sources that couldn't be checked (by component
/// name, with the reason). A source that fails doesn't stop the others.
public struct ComponentUpdateCheck: Sendable {
    public var updates: [ComponentUpdate]
    public var failures: [String: String]
    public var checkedAt: Date
}

extension EnvironmentSetup {
    /// The newest installed version of each component id that came from a known source.
    /// Imported components (D3DMetal, Wine builds chosen from a folder) have no source to check.
    func installedNewest(id: String) -> InstalledComponent? {
        engine.components.installed()
            .filter { $0.manifest.id == id && ComponentCleanup.isRedownloadable($0) }
            .max { VersionNumber($0.manifest.version) < VersionNumber($1.manifest.version) }
    }

    /// Whether `available` is newer than `installed`.
    static func isNewer(_ available: String, than installed: String) -> Bool {
        VersionNumber(available) > VersionNumber(installed)
    }

    /// Looks for newer releases of every installed component that came from a known source,
    /// and records when it looked (`settings.json` `last_component_check`).
    public func checkForUpdates() async -> ComponentUpdateCheck {
        var updates: [ComponentUpdate] = []
        var failures: [String: String] = [:]
        let chosen = engine.components.chosenActiveVersions()

        for source in WineSource.all {
            guard let installed = installedNewest(id: source.id) else { continue }
            do {
                let release = try await latestRelease(of: source)
                if Self.isNewer(release.version, than: installed.manifest.version) {
                    updates.append(ComponentUpdate(
                        id: source.id, kind: .wine, displayName: source.displayName,
                        installedVersion: installed.manifest.version, availableVersion: release.version, release: .wine(release),
                        heldVersion: chosen[installed.manifest.id]
                    ))
                }
            } catch {
                failures[source.displayName] = error.localizedDescription
            }
        }
        for source in GraphicsLayerSource.all {
            guard let installed = installedNewest(id: source.id) else { continue }
            do {
                let release = try await latestRelease(of: source)
                if Self.isNewer(release.version, than: installed.manifest.version) {
                    updates.append(ComponentUpdate(
                        id: source.id, kind: .graphics, displayName: source.displayName,
                        installedVersion: installed.manifest.version, availableVersion: release.version, release: .graphics(release),
                        heldVersion: chosen[installed.manifest.id]
                    ))
                }
            } catch {
                failures[source.displayName] = error.localizedDescription
            }
        }
        if let installed = installedNewest(id: "winetricks") {
            do {
                let version = try await latestWinetricksVersion()
                if Self.isNewer(version, than: installed.manifest.version) {
                    updates.append(ComponentUpdate(
                        id: "winetricks", kind: .winetricks, displayName: "winetricks",
                        installedVersion: installed.manifest.version, availableVersion: version, release: .winetricks(version: version),
                        heldVersion: chosen[installed.manifest.id]
                    ))
                }
            } catch {
                failures["winetricks"] = error.localizedDescription
            }
        }

        let now = Date()
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.lastComponentCheck = now
        try? settings.save(toSupportFolder: engine.paths.root)
        return ComponentUpdateCheck(updates: updates, failures: failures, checkedAt: now)
    }

    /// The updates automatic mode installs: everything not held.
    public static func automatic(_ updates: [ComponentUpdate]) -> [ComponentUpdate] {
        updates.filter { $0.heldVersion == nil }
    }

    /// Whether a daily check is due in the current mode.
    public func isUpdateCheckDue(now: Date = Date()) -> Bool {
        let settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        guard settings.effectiveComponentUpdates != .off else { return false }
        return now.timeIntervalSince(settings.lastComponentCheck ?? .distantPast) > 24 * 60 * 60
    }

    /// Installs an update next to the version it replaces and makes it active. The old
    /// version stays until `DistillerEngine.removeUnusedComponents` finds nothing needs it.
    @discardableResult
    public func install(_ update: ComponentUpdate) async throws -> InstalledComponent {
        let installed: InstalledComponent
        switch update.release {
        case .wine(let release): installed = try await installWine(release)
        case .graphics(let release): installed = try await installGraphicsLayer(release)
        case .winetricks(let version): installed = try await installWinetricks(version: version)
        }
        try engine.components.makeActive(installed)
        return installed
    }
}
