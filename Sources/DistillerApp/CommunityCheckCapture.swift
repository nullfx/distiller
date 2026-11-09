import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import DistillerCore

/// The community check's panel: from the moment the installer starts, a small floating panel
/// (above full-screen games too, without taking focus from them) follows the test bottle. It
/// shows whether the installer is still running and which programs are running, so the
/// player can say which one is the game (many installers start a launcher or the game
/// themselves) or start an installed one. Screenshots can be captured at any point, with a
/// button or ⌃⌥⌘S from inside the game. Everything keeps running until the player answers;
/// they choose which captures to share (up to three) when they submit.
@MainActor
@Observable
final class CommunityCheckCaptureSession {
    static let hotKeyDescription = "⌃⌥⌘S"

    let check: CommunityCheckSession
    /// Normalised JPEGs, in the order taken.
    private(set) var captures: [Data] = []
    private(set) var thumbnails: [NSImage] = []
    private(set) var isCapturing = false
    private(set) var message: String?
    private(set) var flash = false
    /// What's running in the test bottle (Wine's own programs left out), refreshed every few seconds.
    private(set) var running: [ProgramInBottle] = []
    private(set) var installerIsRunning = true
    private(set) var installed: (programs: [ProgramInBottle], suggested: ProgramInBottle?) = ([], nil)
    /// The game's program, chosen by the player (or suggested when it's running).
    var gameProgram: ProgramInBottle?
    /// Checked when the panel opens; granting it only applies after Distiller restarts.
    let hasScreenRecording = ScreenRecordingAccess.isGranted

    private var panel: NSPanel?
    private var hotKey: GlobalHotKey?
    private var refresh: Task<Void, Never>?
    private var continuation: CheckedContinuation<CommunityCheckOutcome, Never>?

    var canCapture: Bool { !isCapturing && captures.count < CommunityMedia.maxCaptures }

    private init(check: CommunityCheckSession) {
        self.check = check
    }

    /// Shows the panel and waits for the player's answer.
    static func run(check: CommunityCheckSession) async -> CommunityCheckOutcome {
        let session = CommunityCheckCaptureSession(check: check)
        return await withCheckedContinuation { continuation in
            session.continuation = continuation
            session.show()
        }
    }

    func capture() {
        guard canCapture else { return }
        isCapturing = true
        message = nil
        let name = gameProgram?.program.name
        Task {
            let raw = await GameWindowCapture.capture(programName: name)
            let jpeg = await Task.detached { raw.flatMap(CommunityMedia.screenshot(from:)) }.value
            isCapturing = false
            guard let jpeg, let image = NSImage(data: jpeg) else {
                message = raw == nil
                    ? "Couldn't capture a window from the test bottle. If macOS asked, allow Distiller in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then try again."
                    : "The window is too small to capture (it needs to be at least \(CommunityMedia.screenshotMinWidth) pixels wide)."
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

    /// Starts an installed program and makes it the game's program.
    func start(_ program: ProgramInBottle) {
        do {
            try check.start(program)
            gameProgram = program
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func finish(_ outcome: CommunityCheckOutcome) {
        refresh?.cancel()
        refresh = nil
        hotKey = nil
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    func works() {
        guard let gameProgram else { return }
        finish(.works(program: gameProgram, screenshots: captures))
    }

    private func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
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
        let hosting = NSHostingView(rootView: CapturePanelView(session: self))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.capture()
        }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let running = await self.check.runningPrograms()
                let check = self.check
                self.installed = await Task.detached { check.installedPrograms() }.value
                self.running = running
                self.installerIsRunning = self.check.installerIsRunning
                if self.gameProgram == nil, let suggested = self.check.suggestedProgramName?.lowercased() {
                    self.gameProgram = running.first { $0.program.name.lowercased() == suggested }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
    }
}

private struct CapturePanelView: View {
    @Bindable var session: CommunityCheckCaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.check.title).font(.headline)
            HStack(spacing: 6) {
                if session.installerIsRunning { ProgressView().controlSize(.mini) }
                Text(session.installerIsRunning ? "The installer is running. Follow its steps." : "The installer has finished.")
                    .font(.callout)
            }
            Text("Some installers start a launcher or the game themselves. Play until \(session.check.title) reaches its login screen or menu, or further, and capture what's worth sharing with \(CommunityCheckCaptureSession.hotKeyDescription) or Capture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            gamePicker

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
            Text("Did it reach its login screen or menu? Answering closes everything in the test bottle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { session.finish(.cancelled) }
                Spacer()
                Button("It Doesn't Work") { session.finish(.doesNotWork) }
                Button("It Works") { session.works() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.gameProgram == nil)
                    .help(session.gameProgram == nil ? "First choose the game's program." : "")
            }
        }
        .padding(16)
        .frame(width: 380)
        .overlay {
            if session.flash {
                Color.white.opacity(0.25).allowsHitTesting(false)
            }
        }
    }

    /// Which running program is the game, or start one that's installed.
    @ViewBuilder private var gamePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The game's program").font(.caption.bold())
            if session.running.isEmpty && session.gameProgram == nil {
                Text("Nothing is running in the test bottle yet, besides the installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("The game's program", selection: $session.gameProgram) {
                    Text("Choose…").tag(ProgramInBottle?.none)
                    ForEach(choices) { program in
                        Text(program.program.name).tag(ProgramInBottle?.some(program)).help(program.windowsPath)
                    }
                }
                .labelsHidden()
                if let program = session.gameProgram {
                    Text(program.windowsPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Menu("Start an Installed Program") {
                if session.installed.programs.isEmpty {
                    Text("No programs are installed yet")
                }
                ForEach(session.installed.programs.prefix(30)) { program in
                    Button(program == session.installed.suggested ? "\(program.windowsPath) (suggested)" : program.windowsPath) {
                        session.start(program)
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// The running programs, plus the chosen one if it isn't among them (just started).
    private var choices: [ProgramInBottle] {
        var list = session.running
        if let chosen = session.gameProgram, !list.contains(chosen) { list.insert(chosen, at: 0) }
        return list
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
