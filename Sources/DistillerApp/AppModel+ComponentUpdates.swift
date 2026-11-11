import Foundation
import DistillerCore

/// Keeping Wine builds, graphics layers and winetricks up to date (Components ▸ Updates).
/// In "ask" and "auto" the app checks when it starts and then once a day; "auto" also installs
/// what it finds (except components the player keeps on an older version) and removes versions
/// nothing needs. Check Now works in every mode.
extension AppModel {
    func setComponentUpdateMode(_ mode: ComponentUpdateMode) {
        guard let engine else { return }
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.componentUpdates = mode
        do {
            try settings.save(toSupportFolder: engine.paths.root)
            componentUpdateMode = mode
        } catch {
            errorMessage = error.localizedDescription
        }
        if mode == .off { componentUpdateMessage = nil }
        checkForComponentUpdatesIfDue()
    }

    /// Checks when the app starts and once a day after (not in "off"). Called on every reload,
    /// so it also starts the hourly timer that notices a day has passed.
    func checkForComponentUpdatesIfDue() {
        guard let setup else { return }
        if componentUpdateTimer == nil {
            componentUpdateTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60 * 60))
                    self?.checkForComponentUpdatesIfDue()
                }
            }
        }
        guard componentUpdateMode != .off, !isCheckingForUpdates else { return }
        guard !hasCheckedComponentsThisSession || setup.isUpdateCheckDue() else { return }
        checkForComponentUpdates(automatic: true)
    }

    /// Looks for updates now. `automatic` checks are quiet, and in "auto" install what they find.
    func checkForComponentUpdates(automatic: Bool = false, includingApp: Bool = true) {
        guard let setup, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        hasCheckedComponentsThisSession = true
        if includingApp { checkForAppUpdate(automatic: automatic) }
        if !automatic { componentUpdateMessage = nil }
        Task {
            let check = await setup.checkForUpdates()
            isCheckingForUpdates = false
            lastComponentCheck = check.checkedAt
            componentUpdates = check.updates
            componentCheckFailures = check.failures
            if !automatic {
                componentUpdateMessage = check.updates.isEmpty && check.failures.isEmpty ? "Everything is up to date." : nil
            }
            let toInstall = EnvironmentSetup.automatic(check.updates)
            if automatic, componentUpdateMode == .auto, !toInstall.isEmpty {
                installComponentUpdates(toInstall)
            }
        }
    }

    func installComponentUpdate(_ update: ComponentUpdate) {
        installComponentUpdates([update])
    }

    /// Installs updates one after another, then removes versions nothing needs.
    func installComponentUpdates(_ updates: [ComponentUpdate]) {
        guard let setup, let engine, !updates.isEmpty else { return }
        perform("Updating components…") {
            var installed: [String] = []
            for update in updates {
                let size = update.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
                self.busyMessage = "Downloading \(update.displayName) \(update.availableVersion)\(size)…"
                try await setup.install(update)
                installed.append("\(update.displayName) \(update.availableVersion)")
                self.componentUpdates.removeAll { $0.id == update.id }
            }
            self.busyMessage = "Removing versions nothing needs…"
            let removed = await engine.removeUnusedComponents()
            var message = "Installed \(installed.joined(separator: ", "))."
            if !removed.isEmpty {
                message += " Removed \(removed.map { "\($0.manifest.displayName)" }.joined(separator: ", "))."
            }
            self.componentUpdateMessage = message
        }
    }

    /// Makes `component` the version new games use and games that follow updates move to.
    func makeActive(_ component: InstalledComponent) {
        guard let engine else { return }
        do {
            try engine.components.makeActive(component)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func removeUnusedComponents() {
        guard let engine else { return }
        perform("Removing versions nothing needs…") {
            let removed = await engine.removeUnusedComponents()
            self.componentUpdateMessage = removed.isEmpty
                ? "Nothing could be removed; a running game may be using it."
                : "Removed \(removed.map(\.manifest.displayName).joined(separator: ", "))."
        }
    }
}
