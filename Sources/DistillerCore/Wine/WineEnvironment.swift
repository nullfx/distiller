import Foundation

/// Builds the environment for every Wine process.
///
/// Layering, lowest to highest: a minimal copy of the host environment, Distiller's defaults,
/// the Wine build's manifest, the graphics layer's manifest, then the resolved recipe.
/// `WINEPREFIX` is set last so nothing can point Wine at another prefix.
public enum WineEnvironment {
    /// Wine's debug output off, and MoltenVK (under DXVK) reporting errors only: its warnings
    /// can repeat many times a second and fill a launch log. Component manifests and recipes
    /// come later in `build`, so either can turn them back up.
    public static let defaults: [String: String] = ["WINEDEBUG": "-all", "MVK_CONFIG_LOG_LEVEL": "1"]

    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"]

    public static func build(
        prefix: URL,
        wine: InstalledComponent,
        graphics: InstalledComponent?,
        resolved: ResolvedRecipe?,
        host: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in inheritedKeys {
            if let value = host[key] { env[key] = value }
        }

        // Wine's own bin first; Homebrew for winetricks' helpers such as cabextract.
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        if let bin = wine.wineBinary?.deletingLastPathComponent().path {
            path.insert(bin, at: 0)
        }
        env["PATH"] = path.joined(separator: ":")

        env.merge(defaults) { _, new in new }
        env.merge(wine.manifest.env ?? [:]) { _, new in new }
        env.merge(graphics?.manifest.env ?? [:]) { _, new in new }

        var overrides = graphics?.manifest.dllOverrides ?? [:]
        if let resolved {
            switch resolved.sync {
            case .msync: env["WINEMSYNC"] = "1"
            case .esync: env["WINEESYNC"] = "1"
            case .none: break
            }
            overrides.merge(resolved.dllOverrides) { _, new in new }
            env.merge(resolved.env) { _, new in new }
        }
        if !overrides.isEmpty {
            env["WINEDLLOVERRIDES"] = dllOverrideString(overrides)
        }

        // Builds that load libraries through @rpath without search paths of their own (made
        // for an app that sets this) find them here. Set last, so recipes can't change it.
        let libraries = wine.manifest.effectiveLibraryPaths.map { wine.directory.appendingPathComponent($0).path }
        if !libraries.isEmpty {
            env[Self.libraryPathKey] = libraries.joined(separator: ":")
        }

        env["WINEPREFIX"] = prefix.path
        return env
    }

    static let libraryPathKey = "DYLD_FALLBACK_LIBRARY_PATH"

    /// macOS removes `DYLD_*` variables when it starts a system program such as `/bin/bash`, so
    /// Wine started from a script (winetricks) loses them. For builds that need them, scripts
    /// get small wrappers (in `folder`) as `WINE` and `WINESERVER` that set the variable again
    /// just before starting Wine, and one for `wine64` when the build has it (winetricks looks
    /// for it next to `WINE`). `environment` gets what winetricks needs to use them: the
    /// wrappers, and `WINE_BINDIR` (the real programs, which winetricks inspects to tell the
    /// kind of Wine; scripts tell it nothing, and it then guesses a `wine64` that isn't there).
    /// False when the build doesn't need them.
    @discardableResult
    static func useScriptWrappers(for wine: InstalledComponent, environment: inout [String: String], in folder: URL) throws -> Bool {
        guard let paths = environment[libraryPathKey], let wineBinary = wine.wineBinary,
              let server = wine.wineserverBinary else { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func wrapper(_ name: String, _ target: URL) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let script = "#!/bin/sh\nexport \(libraryPathKey)=\(shellQuoted(paths))\nexec \(shellQuoted(target.path)) \"$@\"\n"
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        environment["WINE"] = try wrapper("wine", wineBinary).path
        environment["WINESERVER"] = try wrapper("wineserver", server).path
        let wine64 = wineBinary.deletingLastPathComponent().appendingPathComponent("wine64")
        if wine64 != wineBinary, FileManager.default.isExecutableFile(atPath: wine64.path) {
            _ = try wrapper("wine64", wine64)
        }
        environment["WINE_BINDIR"] = wineBinary.deletingLastPathComponent().path
        return true
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Formats overrides the way `WINEDLLOVERRIDES` expects: "d3d11=n,b;dxgi=n".
    public static func dllOverrideString(_ overrides: [String: String]) -> String {
        overrides.keys.sorted().map { name in
            "\(name)=\(shortForm(overrides[name] ?? ""))"
        }.joined(separator: ";")
    }

    static func shortForm(_ value: String) -> String {
        switch value.lowercased() {
        case "native": return "n"
        case "builtin": return "b"
        case "native,builtin": return "n,b"
        case "builtin,native": return "b,n"
        case "disabled": return ""
        default: return value.lowercased()
        }
    }

    /// `environment` with msync and esync turned off, for installing components (winetricks).
    public static func withoutFastSync(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env["WINEMSYNC"] = nil
        env["WINEESYNC"] = nil
        return env
    }
}
