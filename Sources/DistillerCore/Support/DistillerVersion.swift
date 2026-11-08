import Foundation

/// This build's version, from the app bundle's Info.plist, which `Scripts/bundle-app.sh` writes
/// from the repository's VERSION file. The `distiller` command inside the bundle
/// (Contents/Helpers/distiller) reads the app's Info.plist; builds outside a bundle
/// (`swift run`) report "development".
public enum DistillerVersion {
    public static let development = "development"

    public static var current: String {
        if let version = version(fromInfo: Bundle.main.infoDictionary) { return version }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // Distiller.app/Contents/Helpers/distiller → Distiller.app/Contents/Info.plist
            let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
            if let version = version(fromInfo: NSDictionary(contentsOf: plist) as? [String: Any]) { return version }
        }
        return development
    }

    /// The full version (with any pre-release suffix) from an Info.plist dictionary, if it's
    /// Distiller's.
    static func version(fromInfo info: [String: Any]?) -> String? {
        guard let info, info["CFBundleIdentifier"] as? String == "com.nullfx.distiller" else { return nil }
        return (info["DistillerVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String)
    }
}
