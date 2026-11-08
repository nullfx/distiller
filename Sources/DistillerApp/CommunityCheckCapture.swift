import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import DistillerCore

/// The community check's capture panel: while the test game runs, a small floating panel
/// (above full-screen games too, without taking focus from them) lets the player capture
/// screenshots whenever the game shows something worth sharing, with a button or ⌃⌥⌘S from
/// inside the game, and then say whether the game works. The game keeps running until they
/// answer. They choose which captures to share (up to three) when they submit.
@MainActor
@Observable
final class CommunityCheckCaptureSession {
    static let hotKeyDescription = "⌃⌥⌘S"

    let title: String
    let programName: String
    /// Normalised JPEGs, in the order taken.
    private(set) var captures: [Data] = []
    private(set) var thumbnails: [NSImage] = []
    private(set) var isCapturing = false
    private(set) var message: String?
    private(set) var flash = false
    /// Checked when the panel opens; granting it only applies after Distiller restarts.
    let hasScreenRecording = ScreenRecordingAccess.isGranted

    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?
    private var continuation: CheckedContinuation<CommunityCheckAnswer, Never>?

    var canCapture: Bool { !isCapturing && captures.count < CommunityMedia.maxCaptures }

    private init(title: String, programName: String) {
        self.title = title
        self.programName = programName
    }

    /// Shows the panel and waits for the player's answer.
    static func run(title: String, programName: String) async -> CommunityCheckAnswer {
        let session = CommunityCheckCaptureSession(title: title, programName: programName)
        return await withCheckedContinuation { continuation in
            session.continuation = continuation
            session.show()
        }
    }

    func capture() {
        guard canCapture else { return }
        isCapturing = true
        message = nil
        Task {
            let raw = await GameWindowCapture.capture(programName: programName)
            let jpeg = await Task.detached { raw.flatMap(CommunityMedia.screenshot(from:)) }.value
            isCapturing = false
            guard let jpeg, let image = NSImage(data: jpeg) else {
                message = raw == nil
                    ? "Couldn't capture the game's window. If macOS asked, allow Distiller in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then try again."
                    : "The game's window is too small to capture (it needs to be at least \(CommunityMedia.screenshotMinWidth) pixels wide)."
                NSSound.beep()
                return
            }
            captures.append(jpeg)
            thumbnails.append(image)
            NSSound(named: "Pop")?.play()
            flash = true
            try? await Task.sleep(for: .milliseconds(180))
            flash = false
        }
    }

    func finish(works: Bool) {
        hotKey = nil
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: CommunityCheckAnswer(works: works, screenshots: works ? captures : []))
        continuation = nil
    }

    private func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Community Check"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: CapturePanelView(session: self))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 260))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.capture()
        }
        NSApp.requestUserAttention(.informationalRequest)
    }
}

private struct CapturePanelView: View {
    let session: CommunityCheckCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.headline)
            Text("Play until \(session.title) reaches its login screen or menu, or further. Whenever it shows something worth sharing, press \(CommunityCheckCaptureSession.hotKeyDescription) in the game or click Capture. Screenshots the game saves itself are picked up too. You choose up to \(CommunityMedia.maxSharedScreenshots) to share when you submit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !session.hasScreenRecording {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Capturing needs Screen Recording permission for this copy of Distiller. Turn it on (remove and re-add Distiller if it's already on); it applies after Distiller restarts. Until then, use the game's own screenshot key.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { ScreenRecordingAccess.openSettings() }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                if session.thumbnails.isEmpty {
                    Text("No screenshots yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.thumbnails.suffix(4).enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .frame(width: 64, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text("\(session.captures.count) of \(CommunityMedia.maxCaptures)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    session.capture()
                } label: {
                    if session.isCapturing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Capture", systemImage: "camera")
                    }
                }
                .disabled(!session.canCapture)
                .help("Capture the game's window (\(CommunityCheckCaptureSession.hotKeyDescription) works from inside the game)")
            }
            .frame(minHeight: 36)

            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Did it reach its login screen or menu? Answering closes the game.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("It Doesn't Work") { session.finish(works: false) }
                Spacer()
                Button("It Works") { session.finish(works: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
        .overlay {
            if session.flash {
                Color.white.opacity(0.25).allowsHitTesting(false)
            }
        }
    }
}

/// A system-wide keyboard shortcut (Carbon `RegisterEventHotKey`), which works while another
/// app, such as a full-screen game, is in front, and needs no Accessibility permission.
/// Unregistered when released.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4453_544C), id: 1) // "DSTL"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
