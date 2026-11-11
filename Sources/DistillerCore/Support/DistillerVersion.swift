import Foundation

/// This build's version, from the app bundle's Info.plist, which `Scripts/bundle-app.sh` writes
/// from the repository's VERSION file. The `distiller` command inside the bundle
/// (Contents/Helpers/distiller) reads the app's Info.plist; builds outside a bundle
/// (`swift run`) report "development".
public enum DistillerVersion {
    public static let development = "development"

    public static var current: String {
        version(fromInfo: appInfo()) ?? development
    }

    /// The Distiller.app this code runs from: the app itself, or the app around the `distiller`
    /// command in Contents/Helpers. Nil outside a bundle (`swift run`).
    public static var appBundle: URL? {
        if version(fromInfo: Bundle.main.infoDictionary) != nil { return Bundle.main.bundleURL }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        // Distiller.app/Contents/Helpers/distiller → Distiller.app
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return version(fromInfo: info) != nil ? app : nil
    }

    /// That app's Info.plist.
    static func appInfo() -> [String: Any]? {
        if version(fromInfo: Bundle.main.infoDictionary) != nil { return Bundle.main.infoDictionary }
        guard let app = appBundle else { return nil }
        return NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// The full version (with any pre-release suffix) from an Info.plist dictionary, if it's
    /// Distiller's.
    static func version(fromInfo info: [String: Any]?) -> String? {
        guard let info, info["CFBundleIdentifier"] as? String == "com.nullfx.distiller" else { return nil }
        return (info["DistillerVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String)
    }
}
