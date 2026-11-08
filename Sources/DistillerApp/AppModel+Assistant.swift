import Foundation
import DistillerCore

/// The AI troubleshooting assistant switch, and the Claude Desktop connection.
extension AppModel {
    var assistantEnabled: Bool {
        guard let engine else { return true }
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

    /// The `distiller` command inside this app bundle, which serves `distiller mcp`.
    var bundledServer: URL? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/distiller")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    var claudeDesktopCommand: String? { ClaudeDesktopConfig().configuredCommand() }

    func connectClaudeDesktop(_ connect: Bool) {
        do {
            if connect {
                guard let server = bundledServer else {
                    errorMessage = "Connecting needs the bundled app (Scripts/bundle-app.sh), which includes the distiller command."
                    return
                }
                try ClaudeDesktopConfig().connect(serverExecutable: server)
            } else {
                try ClaudeDesktopConfig().disconnect()
            }
            restartEngine()   // refreshes the views that show the connection
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
