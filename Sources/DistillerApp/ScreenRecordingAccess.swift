import AppKit
import CoreGraphics

/// Screen Recording permission, which capturing the game's window needs.
enum ScreenRecordingAccess {
    /// Whether this copy of Distiller may capture windows now. macOS ties the permission to the
    /// app's signature, so it can be off for a rebuilt copy even when the list shows Distiller.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Distiller to the Screen Recording list (macOS asks the first time) and opens it.
    static func openSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
