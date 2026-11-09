import AppKit
import Foundation
import ScreenCaptureKit

/// Captures a running Windows game's window for the community check's screenshot.
///
/// Wine's Mac driver shows each Windows program as its own app, usually named after the
/// program ("Game.exe"). The capture takes that app's largest window on its own (not the
/// screen), so Distiller's question on top of it, and anything else, stays out of the picture.
/// The first capture makes macOS ask for Screen Recording permission; without it there's
/// simply no screenshot.
enum GameWindowCapture {
    /// `programName` ("Game.exe") prefers that program's windows; without it, the largest
    /// window of any Windows program.
    static func capture(programName: String?) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let name = programName?.lowercased()
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let usable = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ownProcess else { return false }
            return window.windowLayer == 0 && window.frame.width >= 320 && window.frame.height >= 200
        }
        func appName(_ window: SCWindow) -> String { window.owningApplication?.applicationName.lowercased() ?? "" }
        // The program's own windows first; otherwise any Wine program's.
        let named: [SCWindow] = name.map { name in
            let stem = (name as NSString).deletingPathExtension
            return usable.filter { appName($0) == name || appName($0) == stem || appName($0).hasPrefix(stem) }
        } ?? []
        let wine = usable.filter { let app = appName($0); return app.hasSuffix(".exe") || app.contains("wine") }
        guard let window = (named.isEmpty ? wine : named).max(by: { area($0) < area($1) }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func area(_ window: SCWindow) -> CGFloat { window.frame.width * window.frame.height }
}
