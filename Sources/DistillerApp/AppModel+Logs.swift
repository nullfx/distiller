import AppKit
import DistillerCore

/// Keeping the Logs folder in check (Settings ▸ Storage ▸ Logs): old logs and the oldest over
/// the size limit are removed when Distiller starts and at most once a day after that.
extension AppModel {
    private static let lastLogCleanupKey = "lastLogCleanup"

    var logSettings: StorageSettings {
        guard let engine else { return StorageSettings() }
        return StorageSettings.load(fromSupportFolder: engine.paths.root)
    }

    func setLogRetention(days: Int) {
        updateLogSettings { $0.logRetentionDays = days }
    }

    func setLogLimit(megabytes: Int) {
        updateLogSettings { $0.logLimitMB = megabytes }
    }

    private func updateLogSettings(_ change: (inout StorageSettings) -> Void) {
        guard let engine else { return }
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        change(&settings)
        do {
            try settings.save(toSupportFolder: engine.paths.root)
            refreshLogUsage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLogUsage() {
        guard let engine else { return }
        Task {
            logUsage = await Task.detached { engine.logUsage() }.value
        }
    }

    /// Cleans up now, and says what it did.
    func cleanUpLogs() {
        guard let engine else { return }
        perform("Cleaning up logs…") {
            let result = await Task.detached { engine.cleanLogs() }.value
            UserDefaults.standard.set(Date(), forKey: Self.lastLogCleanupKey)
            self.logCleanupMessage = result.removed == 0
                ? "Nothing to remove."
                : "Removed \(result.removed) log\(result.removed == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file))."
            self.logUsage = await Task.detached { engine.logUsage() }.value
        }
    }

    func showLogsFolder() {
        guard let engine else { return }
        try? FileManager.default.createDirectory(at: engine.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(engine.paths.logs)
    }

    /// Cleans up quietly if it's been a day since the last time.
    func cleanUpLogsIfDue() {
        guard let engine else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastLogCleanupKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastLogCleanupKey)
        Task.detached(priority: .utility) { engine.cleanLogs() }
    }
}
