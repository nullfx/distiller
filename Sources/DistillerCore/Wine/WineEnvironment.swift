import Foundation

/// Builds the environment for every Wine process.
///
/// Layering, lowest to highest: a minimal copy of the host environment, Distiller's defaults,
/// the Wine build's manifest, the graphics layer's manifest, then the resolved recipe.
/// `WINEPREFIX` is set last so nothing can point Wine at another prefix.
public enum WineEnvironment {
    public static let defaults: [String: String] = ["WINEDEBUG": "-all"]

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

        env["WINEPREFIX"] = prefix.path
        return env
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
}
