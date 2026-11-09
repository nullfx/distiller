import AppKit
import SwiftUI
import DistillerCore

/// A window for downloading a file from a publisher's download page, for installers with no
/// direct link that works on its own (`user_download` steps, and the community check of an
/// installer with only a download page). The player clicks the download in Distiller's private
/// browser; the file is checked (`verify`, when there's something to check it against) before
/// it can be used, so the wrong download is caught while they're still on the page.
///
/// A window rather than a sheet, because it can be needed while other sheets are open (the
/// community check starts from the Submit sheet).
@MainActor
final class PageDownloadWindow: NSObject, NSWindowDelegate {
    private let capture: InstallerCaptureModel
    private var window: NSWindow?
    private var continuation: CheckedContinuation<URL?, Never>?
    private static var open: [PageDownloadWindow] = []

    private init(request: PageDownloadRequest, verify: (@Sendable (URL) throws -> Void)?) {
        capture = InstallerCaptureModel(startPage: request.page)
        capture.verify = verify ?? { _ in }
        super.init()
    }

    /// Shows the page and waits for a checked file, or nil if the player cancels. The file is in
    /// a temporary folder of its own; remove it with `removeDownload` once it's been used.
    static func obtain(_ request: PageDownloadRequest, verify: (@Sendable (URL) throws -> Void)?) async -> URL? {
        let controller = PageDownloadWindow(request: request, verify: verify)
        open.append(controller)
        return await withCheckedContinuation { continuation in
            controller.continuation = continuation
            controller.show(request)
        }
    }

    /// Removes a file `obtain` returned, and its temporary folder.
    static func removeDownload(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix("distiller-installer-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func show(_ request: PageDownloadRequest) {
        let view = PageDownloadView(request: request, capture: capture) { [weak self] file in
            self?.finish(file)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Download \(request.title)'s Installer"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(_ file: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        capture.discardDownload()
        window?.delegate = nil
        window?.close()
        window = nil
        Self.open.removeAll { $0 === self }
        continuation.resume(returning: file)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}

/// The page-download window's content: what to download, the browser, and the file's check.
private struct PageDownloadView: View {
    let request: PageDownloadRequest
    @Bindable var capture: InstallerCaptureModel
    let done: (URL?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.prompt).font(.headline)
                Text("This is the publisher's download page on \(request.page.host ?? request.page.absoluteString). Click its download for Windows; Distiller checks the file is the installer the recipe expects before using it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 14)
            BrowserAddressBar(capture: capture)
            Divider()
            WebViewHost(capture: capture)
                .frame(minHeight: 360)
            Divider()
            status
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch capture.state {
            case .browsing, .testing, .result:
                Text("Waiting for the download. If the page asks, choose the Windows version.")
                    .foregroundStyle(.secondary)
            case .downloading(let name, let fraction):
                HStack {
                    Text("Downloading \(name)…")
                    ProgressView(value: fraction).frame(maxWidth: 240)
                }
            case .checking(let name):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking \(name)…")
                }
            case .obtained(let file):
                Label("\(file.lastPathComponent) is the installer the recipe expects.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .rejected(let name, let reason):
                Label("\(name) isn't the installer the recipe expects, so it won't be used: \(reason) Try the page's other Windows download, or a different version if the page offers one.", systemImage: "xmark.octagon")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = capture.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Private browsing: nothing is kept after you close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use This File") { done(capture.takeObtainedFile()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isObtained)
            }
        }
        .padding(14)
    }

    private var isObtained: Bool {
        if case .obtained = capture.state { return true }
        return false
    }
}
