import Foundation
import DistillerCore

/// The AI troubleshooting assistant switch, and the `distiller` command AI apps start.
extension AppModel {
    var assistantEnabled: Bool {
        guard let engine else { return false }
        return StorageSettings.load(fromSupportFolder: engine.paths.root).isAssistantEnabled
    }

    func setAssistantEnabled(_ enabled: Bool) {
        guard let engine else { return }
        do {
            var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
            settings.assistantEnabled = enabled
            try settings.save(toSupportFolder: engine.paths.root)
            restartEngine()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The `distiller` command inside this app bundle, which AI apps start as `distiller mcp`.
    var bundledServer: URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/distiller")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }
}
