import AppKit
import Foundation
import DistillerCore

/// Distiller's own updates, from the GitHub repository this copy was built from
/// (`AppUpdater.configuredRepository`): checked with component updates, announced once per
/// version, and installed only when the player says so, because installing relaunches the app.
extension AppModel {
    static let announcedAppVersionKey = "AnnouncedAppUpdateVersion"

    var appUpdateRepository: String? { AppUpdater.configuredRepository }

    func checkForAppUpdate(automatic: Bool) {
        guard let repository = appUpdateRepository else {
            if !automatic { appUpdateStatus = "This build doesn't say where its updates come from." }
            return
        }
        Task {
            do {
                let release = try await AppUpdater(repository: repository).latestRelease()
                if AppUpdater.isNewer(release.version, than: DistillerVersion.current) {
                    appUpdate = release
                    appUpdateStatus = nil
                    let announced = UserDefaults.standard.string(forKey: Self.announcedAppVersionKey)
                    if automatic, announced != release.version {
                        UserDefaults.standard.set(release.version, forKey: Self.announcedAppVersionKey)
                        appUpdateToAnnounce = release
                    }
                } else {
                    appUpdate = nil
                    appUpdateStatus = "Distiller is up to date."
                }
            } catch {
                if !automatic { appUpdateStatus = "Couldn't check for a new Distiller: \(error.localizedDescription)" }
            }
        }
    }

    /// Distiller ▸ Check for Updates…: checks Distiller and the components now, and always
    /// says what it found: the install alert for a new Distiller, otherwise a summary.
    func checkForUpdatesFromMenu() {
        checkForComponentUpdates(includingApp: false)
        Task {
            var appLine: String
            if let repository = appUpdateRepository {
                do {
                    let release = try await AppUpdater(repository: repository).latestRelease()
                    if AppUpdater.isNewer(release.version, than: DistillerVersion.current) {
                        appUpdate = release
                        appUpdateStatus = nil
                        UserDefaults.standard.set(release.version, forKey: Self.announcedAppVersionKey)
                        appUpdateToAnnounce = release
                        return
                    }
                    appUpdate = nil
                    appUpdateStatus = "Distiller is up to date."
                    appLine = "Distiller \(DistillerVersion.current) is the latest version."
                } catch {
                    appLine = "Couldn't check for a new Distiller: \(error.localizedDescription)"
                }
            } else {
                appLine = "This build of Distiller doesn't say where its updates come from, so it can't check for itself."
            }
            while isCheckingForUpdates { try? await Task.sleep(for: .milliseconds(200)) }
            let count = componentUpdates.count
            let componentLine: String
            if count > 0 {
                componentLine = count == 1 ? "1 update for Wine, graphics layers or winetricks is available." : "\(count) updates for Wine, graphics layers or winetricks are available."
            } else if !componentCheckFailures.isEmpty {
                componentLine = "Some components couldn't be checked: \(componentCheckFailures.keys.sorted().joined(separator: ", "))."
            } else {
                componentLine = "Wine, graphics layers and winetricks are up to date."
            }
            updateCheckSummary = UpdateCheckSummary(
                title: count > 0 ? "Component updates available" : "You're up to date",
                message: "\(appLine) \(componentLine)",
                hasComponentUpdates: count > 0
            )
        }
    }

    /// Why the app can't be replaced right now, if it can't: something is running that
    /// quitting would interrupt.
    func appUpdateBlocker() async -> String? {
        if busyMessage != nil { return "Wait until \(busyMessage ?? "the current task") finishes." }
        if !running.isEmpty { return "Quit your running games first." }
        guard let engine else { return nil }
        // Any Wine from Distiller's components still running (an install, a community check, a launcher).
        let components = engine.paths.components.standardizedFileURL.path + "/"
        let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axww", "-o", "command="])
        if result?.output.contains(components) == true {
            return "Windows programs are still running in a bottle. Quit them (or wait for the install or check to finish) first."
        }
        return nil
    }

    /// Downloads, checks and installs `release`, then relaunches. If the app can't be replaced
    /// where it is (a read-only folder, or opened straight from a disk image), opens the checked
    /// disk image instead, for the player to drag to Applications.
    func installAppUpdate(_ release: AppRelease) {
        guard let repository = appUpdateRepository, !isInstallingAppUpdate else { return }
        Task {
            if let blocker = await appUpdateBlocker() {
                errorMessage = "Distiller can't update now. \(blocker)"
                return
            }
            isInstallingAppUpdate = true
            defer { isInstallingAppUpdate = false }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-app-update-\(UUID().uuidString)", isDirectory: true)
            do {
                let size = release.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
                appUpdateStatus = "Downloading Distiller \(release.version)\(size)…"
                let image = try await AppUpdater(repository: repository).download(release, into: folder)
                appUpdateStatus = "Checking the download…"
                let mounted = try await AppBundleCheck.attach(image)
                guard let current = DistillerVersion.appBundle else {
                    await AppBundleCheck.detach(mounted.mountPoint)
                    throw DistillerError.setupFailed("This copy isn't running from an app bundle, so it can't replace itself.")
                }
                do {
                    try await AppBundleCheck.verify(mounted.app, replacing: current, version: release.version)
                } catch {
                    await AppBundleCheck.detach(mounted.mountPoint)
                    throw error
                }
                guard AppReplacer.canReplace(current) else {
                    await AppBundleCheck.detach(mounted.mountPoint)
                    NSWorkspace.shared.open(image)
                    appUpdateStatus = "Distiller can't replace itself where it is (\(current.deletingLastPathComponent().path)). The checked disk image is open: drag Distiller to Applications, replacing this copy."
                    return
                }
                appUpdateStatus = "Installing…"
                try await AppReplacer.replace(current, with: mounted.app)
                await AppBundleCheck.detach(mounted.mountPoint)
                try? FileManager.default.removeItem(at: folder)
                try AppReplacer.reopenAfterExit(current)
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                appUpdateStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// What Check for Updates… found, when there's no new Distiller to install.
struct UpdateCheckSummary: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var hasComponentUpdates: Bool
}
