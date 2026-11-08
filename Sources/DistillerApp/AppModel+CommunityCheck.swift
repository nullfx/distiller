import AppKit
import CoreGraphics
import Foundation
import DistillerCore

/// Runs the community check: an alert to choose the program, then the capture panel
/// (CommunityCheckCapture.swift) while the game runs, for screenshots and the verdict.
extension AppModel {
    func runCommunityCheck(for game: Game) {
        guard let engine else { return }
        // Ask about Screen Recording before installing anything, not when Capture fails.
        if !ScreenRecordingAccess.isGranted {
            switch Self.askAboutScreenRecording() {
            case .alertFirstButtonReturn:
                ScreenRecordingAccess.openSettings()
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        let prompts = CommunityCheckPrompts(
            chooseProgram: { programs, suggested in
                await MainActor.run { Self.askForProgram(programs, suggested: suggested) }
            },
            confirmRunning: { title, programName in
                await CommunityCheckCaptureSession.run(title: title, programName: programName)
            }
        )
        perform("Running the community check for \(game.title)…") {
            _ = try await engine.runCommunityCheck(for: game, prompts: prompts) { message in
                Task { @MainActor in self.busyMessage = message }
            }
        }
    }

    private static func askAboutScreenRecording() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Distiller can't capture screenshots yet"
        alert.informativeText = """
            To capture the game's window during the check, Distiller needs Screen Recording permission. macOS ties that permission to the app's signature, so a rebuilt or updated copy of Distiller can need it again even when Distiller is already switched on in the list.

            Open Privacy Settings, turn Distiller on (if it's already on, remove it with − and add it again), then quit and reopen Distiller and start the check again.

            You can also continue without it: screenshots the game saves itself, with its own screenshot key, are still collected.
            """
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Continue Without Captures")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    // MARK: Leftover test bottles

    /// Offers to delete test bottles that interrupted community checks left behind, after
    /// copying the screenshots the game saved in them to ~/Pictures/Distiller.
    func offerToRemoveOrphanedCheckBottles() {
        guard let engine else { return }
        let orphans = engine.orphanedCommunityCheckBottles()
        guard !orphans.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = orphans.count == 1
            ? "A community check didn't finish and left its test bottle behind"
            : "\(orphans.count) community checks didn't finish and left their test bottles behind"
        alert.informativeText = orphans.map { "• \($0.name), \($0.createdAt.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
            + "\n\nTest bottles hold a full copy of the game, so they can be large. Before deleting, Distiller copies any screenshots the game saved in them to Pictures ▸ Distiller."
        alert.addButton(withTitle: orphans.count == 1 ? "Delete It" : "Delete Them")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("Removing leftover test bottles…") {
            var rescued: [URL] = []
            for bottle in orphans {
                self.busyMessage = "Removing \(bottle.name)…"
                rescued += try await Task.detached { try engine.removeOrphanedCommunityCheckBottle(bottle) }.value
            }
            if !rescued.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(rescued) }
        }
    }

    private static func askForProgram(_ programs: [ProgramInBottle], suggested: ProgramInBottle?) -> ProgramInBottle? {
        let alert = NSAlert()
        alert.messageText = "Which program starts the game?"
        alert.informativeText = "The installer has finished. Choose the program players launch; Distiller suggests the one your recipe uses."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        let shown = Array(programs.prefix(40))
        popup.addItems(withTitles: shown.map(\.windowsPath))
        if let suggested, let index = shown.firstIndex(of: suggested) { popup.selectItem(at: index) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Launch It")
        alert.addButton(withTitle: "Cancel Check")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return shown[popup.indexOfSelectedItem]
    }
}
