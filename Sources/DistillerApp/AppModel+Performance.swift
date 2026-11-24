import Foundation
import DistillerCore

/// Recording performance (`PerformanceRecordingSession`): a game has to start ready to record
/// (the Metal HUD's frame log only turns on when a program starts), so Record Performance…
/// starts the game that way, or opens the panel for a game already started that way. Games
/// start ready to record only then, unless the player chooses always (Settings ▸ Games).
extension AppModel {
    func recordPerformance(_ game: Game) {
        guard let engine else { return }
        if let session = performanceSessions[game.id] {
            session.show()
            return
        }
        if game.steam != nil || isSteamLauncher(game) {
            errorMessage = "Recording performance doesn't work yet for games started through Steam."
            return
        }
        let recorder: PerformanceRecorder
        if running[game.id] != nil {
            guard let existing = recorders[game.id] else {
                errorMessage = "\(game.title) was started without recording. Quit it, then choose Record Performance… again: that starts it ready to record."
                return
            }
            recorder = existing
        } else {
            recorder = PerformanceRecorder()
            launch(game, recorder: recorder)
        }
        let session = PerformanceRecordingSession(game: game, recorder: recorder, engine: engine) { [weak self] in
            self?.performanceSessions[game.id] = nil
        }
        performanceSessions[game.id] = session
        session.show()
    }

    /// ⌘ as Ctrl and Option as Alt in Windows programs; applied to a bottle before each launch.
    func setKeyboard(commandAsCtrl: Bool? = nil, optionAsAlt: Bool? = nil) {
        guard let engine else { return }
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        if let commandAsCtrl { settings.commandAsCtrl = commandAsCtrl ? nil : false }
        if let optionAsAlt { settings.optionAsAlt = optionAsAlt ? true : nil }
        do {
            try settings.save(toSupportFolder: engine.paths.root)
            self.commandAsCtrl = settings.isCommandCtrl
            self.optionAsAlt = settings.isOptionAlt
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRecordPerformanceAlways(_ always: Bool) {
        guard let engine else { return }
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.recordPerformanceAlways = always ? true : nil
        do {
            try settings.save(toSupportFolder: engine.paths.root)
            recordPerformanceAlways = always
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
