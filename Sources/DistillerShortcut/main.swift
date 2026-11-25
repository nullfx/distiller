import AppKit
import Foundation

// A game's shortcut app (`<Title>.app`, made by Distiller's Create Shortcut App…): opening it
// starts the game through Distiller's command line, without Distiller's window, as if the game
// were a Mac app. It runs in the background (no Dock icon of its own; the game shows its own)
// and waits for the game to exit, so Distiller records the play time. If the game can't start
// (it's no longer in the library, its drive isn't connected, Distiller isn't installed), it says
// so and offers to open Distiller. Distiller is found by its bundle identifier each time, so
// moving or updating it doesn't break shortcuts.

let distillerID = "com.nullfx.distiller"

struct Shortcut: Decodable {
    var gameID: String
    var title: String
    /// The Distiller that made the shortcut, tried first.
    var distillerApp: String?

    enum CodingKeys: String, CodingKey {
        case title
        case gameID = "game_id"
        case distillerApp = "distiller_app"
    }
}

func fail(_ message: String, distiller: URL?) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .warning
    if distiller != nil {
        alert.addButton(withTitle: "Open Distiller")
        alert.addButton(withTitle: "OK")
    } else {
        alert.addButton(withTitle: "OK")
    }
    if alert.runModal() == .alertFirstButtonReturn, let distiller {
        NSWorkspace.shared.openApplication(at: distiller, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(10))
    }
    exit(1)
}

guard let file = Bundle.main.url(forResource: "shortcut", withExtension: "json"),
      let data = try? Data(contentsOf: file),
      let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else {
    fail("This shortcut is damaged. Make it again from Distiller: right-click the game ▸ Create Shortcut App…", distiller: nil)
}

// The Distiller that made it, if it's still there; else whichever copy macOS knows.
let maker = shortcut.distillerApp.map { URL(fileURLWithPath: $0) }.flatMap { url -> URL? in
    Bundle(url: url)?.bundleIdentifier == distillerID ? url : nil
}
guard let distiller = maker ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: distillerID) else {
    fail("\(shortcut.title) needs Distiller, which isn't installed on this Mac.", distiller: nil)
}
let helper = distiller.appendingPathComponent("Contents/Helpers/distiller")
guard FileManager.default.isExecutableFile(atPath: helper.path) else {
    fail("This copy of Distiller can't start games from shortcuts. Update Distiller.", distiller: distiller)
}

let process = Process()
process.executableURL = helper
process.arguments = ["launch", shortcut.gameID, "--from-shortcut"]
let errors = Pipe()
process.standardError = errors
process.standardOutput = FileHandle.nullDevice
do {
    try process.run()
} catch {
    fail("\(shortcut.title) couldn't start: \(error.localizedDescription)", distiller: distiller)
}
let output = errors.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
guard process.terminationStatus != 0 else { exit(0) }

// The command line's own message, without its "Error: " prefix.
let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
let reason = (lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Distiller couldn't start it.")
    .replacingOccurrences(of: "Error: ", with: "")
fail("\(shortcut.title) couldn't start. \(reason)", distiller: distiller)
