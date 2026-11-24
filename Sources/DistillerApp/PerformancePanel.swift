import AppKit
import Charts
import Observation
import SwiftUI
import DistillerCore

/// Recording a game's performance: a small floating panel (above full-screen games, without
/// taking focus from them, like the community check's) for a game started ready to record
/// (`MeasuredLaunch`). The player sets the game up first (resolution, detail), gets past
/// loading screens, then starts and stops recording; the panel shows the frame rate live and,
/// after stopping, what was measured. Each recording is saved on this Mac
/// (`DistillerEngine.savePerformanceRecord`); nothing leaves it from here.
@MainActor
@Observable
final class PerformanceRecordingSession {
    /// Shorter recordings are kept, but flagged: a report needs a couple of minutes of play.
    static let minimumSeconds = 120.0

    let game: Game
    let recorder: PerformanceRecorder
    private let engine: DistillerEngine
    private let onClose: () -> Void

    private(set) var live: PerformanceRecorder.Live
    private(set) var display: DisplayInfo?
    private(set) var gameIsRunning = true
    private(set) var summary: PerformanceSummary?
    private(set) var saved: PerformanceRecord?
    private(set) var message: String?
    private let opened = Date()
    var settings = PlaySettings()
    var capText = ""
    var renderText = ""

    private var panel: NSPanel?
    private var refresh: Task<Void, Never>?

    init(game: Game, recorder: PerformanceRecorder, engine: DistillerEngine, onClose: @escaping () -> Void) {
        self.game = game
        self.recorder = recorder
        self.engine = engine
        self.onClose = onClose
        live = recorder.live
    }

    /// Frames arrived in the last few seconds.
    var isDrawing: Bool {
        guard let last = live.lastFrames else { return false }
        return Date().timeIntervalSince(last) < 4
    }

    /// No frames long after the game started: it doesn't draw with Metal.
    var noFramesYet: Bool {
        live.lastFrames == nil && Date().timeIntervalSince(opened) > 45
    }

    func start() {
        summary = nil
        saved = nil
        message = nil
        recorder.start()
        live = recorder.live
        updateDisplay()
    }

    func stop() {
        guard live.isRecording else { return }
        summary = recorder.stop()
        live = recorder.live
        if summary == nil {
            message = "No frames arrived while recording."
        }
        save()
    }

    func gameExited() {
        gameIsRunning = false
        if live.isRecording { stop() }
    }

    /// Saves (or saves again, after the player changed the game's settings) the latest recording.
    func save() {
        guard let summary else { return }
        settings.capFPS = settings.frameLimit == .cap ? Int(capText.trimmingCharacters(in: .whitespaces)) : nil
        let render = renderText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "×", with: "x")
        settings.renderResolution = PlaySettings.isResolution(render) ? render : nil
        var record = saved ?? engine.performanceRecord(for: game, summary: summary, settings: settings, display: display)
        record.settings = settings
        record.display = display
        do {
            _ = try engine.savePerformanceRecord(record)
            saved = record
        } catch {
            message = "Couldn't save the recording: \(error.localizedDescription)"
        }
    }

    func close() {
        if live.isRecording { stop() } else { save() }
        refresh?.cancel()
        panel?.close()
        panel = nil
        onClose()
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Record Performance"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        let hosting = NSHostingView(rootView: PerformancePanelView(session: self))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.live = self.recorder.live
                if self.display == nil, self.live.pid != nil { self.updateDisplay() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func updateDisplay() {
        guard let pid = live.pid, let info = GameDisplay.info(pid: pid) else { return }
        display = info
    }
}

/// The game's window size in pixels and its screen's refresh rate, from the window server's
/// list (window bounds need no Screen Recording permission). The process is the one whose
/// frames the HUD reported.
enum GameDisplay {
    static func info(pid: Int) -> DisplayInfo? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let bounds = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { return nil }
            return rect
        }
        guard let largest = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }),
              largest.width >= 320, largest.height >= 200 else { return nil }
        // Window-server coordinates start at the top left of the main screen; AppKit's at the bottom left.
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let flipped = CGRect(x: largest.minX, y: mainHeight - largest.maxY, width: largest.width, height: largest.height)
        let screen = NSScreen.screens.max { $0.frame.intersection(flipped).area < $1.frame.intersection(flipped).area }
        let scale = screen?.backingScaleFactor ?? 1
        return DisplayInfo(
            refreshHz: screen.map { $0.maximumFramesPerSecond },
            window: "\(Int((largest.width * scale).rounded()))x\(Int((largest.height * scale).rounded()))"
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private struct PerformancePanelView: View {
    @Bindable var session: PerformanceRecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.game.title).font(.headline)
            status
            if let summary = session.summary {
                SummaryView(summary: summary, display: session.display)
            } else if !session.live.isRecording {
                Text("Set the game's resolution and graphics detail first, then get into play, past loading screens: they lower the result. Then start recording, and play for at least two minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GameSettingsForm(session: session)
            if let message = session.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder private var status: some View {
        let live = session.live
        if live.isRecording {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                Text("Recording \(Self.duration(live.recordedSeconds))")
                    .monospacedDigit()
                Spacer()
                if session.isDrawing, let fps = live.fps { Text("\(Int(fps.rounded())) fps").monospacedDigit() }
            }
            .font(.callout)
        } else if !session.gameIsRunning {
            Text("\(session.game.title) has quit.").font(.callout)
        } else if session.isDrawing, let fps = session.live.fps {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.secondary)
                Text("Drawing at \(Int(fps.rounded())) fps").monospacedDigit()
            }
            .font(.callout)
        } else if session.noFramesYet {
            Text("No frame timings from \(session.game.title) yet. They come from Metal, so they're there when the game draws with D3DMetal, DXMT or DXVK. WineD3D draws with OpenGL and can't be recorded yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for \(session.game.title) to draw…").font(.callout)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if session.live.isRecording {
                Button("Stop Recording") { session.stop() }
                    .keyboardShortcut(.defaultAction)
                if session.live.recordedSeconds < PerformanceRecordingSession.minimumSeconds {
                    Text("Reports need 2 minutes").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(session.summary == nil ? "Start Recording" : "Record Again") { session.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.gameIsRunning || !session.isDrawing)
            }
            Spacer()
            Button("Done") { session.close() }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The game's own settings, which only the player knows.
private struct GameSettingsForm: View {
    @Bindable var session: PerformanceRecordingSession

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Detail")
                Picker("Detail", selection: $session.settings.detail) {
                    Text("Not set").tag(PlaySettings.Detail?.none)
                    ForEach(PlaySettings.Detail.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Frame limit")
                HStack {
                    Picker("Frame limit", selection: $session.settings.frameLimit) {
                        Text("Not set").tag(PlaySettings.FrameLimit?.none)
                        ForEach(PlaySettings.FrameLimit.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    if session.settings.frameLimit == .cap {
                        TextField("fps", text: $session.capText).frame(width: 50)
                    }
                }
            }
            GridRow {
                Text("Renders at")
                TextField("Same as window", text: $session.renderText)
                    .help("The game's resolution setting when it's lower than its window, such as 1920x1080")
            }
            GridRow {
                Text("Upscaling")
                Picker("Upscaling", selection: $session.settings.upscaling) {
                    Text("Not set").tag(PlaySettings.Upscaling?.none)
                    ForEach(PlaySettings.Upscaling.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .labelsHidden()
            }
            if let display = session.display {
                GridRow {
                    Text("Display")
                    Text([display.window.map { $0.replacingOccurrences(of: "x", with: " × ") + " window" },
                          display.refreshHz.map { "\($0) Hz screen" }].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct SummaryView: View {
    let summary: PerformanceSummary
    let display: DisplayInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                figure("Average", "\(summary.fpsAverage.formatted(.number.precision(.fractionLength(1)))) fps")
                figure("1% low", "\(summary.fps1PercentLow.formatted(.number.precision(.fractionLength(1))))")
                figure("0.1% low", "\(summary.fps01PercentLow.formatted(.number.precision(.fractionLength(1))))")
            }
            Text("\(PerformancePanelView.duration(summary.seconds)) recorded · typical frame \(summary.frameMsMedian.formatted()) ms"
                 + (summary.gpuMsMedian.map { " · GPU \($0.formatted()) ms" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hz = display?.refreshHz, summary.fpsAverage >= Double(hz) * 0.9 {
                Text("Close to the screen's \(hz) Hz: with vsync on, the game can't go faster than the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.timelineFPS.count >= 2 {
                Chart(Array(summary.timelineFPS.enumerated()), id: \.offset) { minute, fps in
                    LineMark(x: .value("Minute", minute + 1), y: .value("fps", fps))
                }
                .chartXAxisLabel("minute")
                .chartYAxisLabel("fps")
                .frame(height: 80)
            }
            Text("Saved on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
