import AppKit
import Observation
import SwiftUI
import DistillerCore

/// An install in progress, as the install window shows it: every step from the start
/// (`InstallPlan`), which are done, which is running and for how long, and how it ended.
@MainActor
@Observable
final class InstallSession {
    enum State: Equatable {
        case running
        case installed
        case failed(String)
        case cancelled
    }

    let title: String
    let tasks: [InstallTask]
    let cancellation = InstallCancellation()
    let startedAt = Date()
    /// The running step, from 1.
    private(set) var step = 1
    private(set) var stepStartedAt = Date()
    /// What the running step last said, when it adds to its title.
    private(set) var detail: String?
    private(set) var state = State.running
    var isConfirmingCancel = false

    init(title: String, tasks: [InstallTask]) {
        self.title = title
        self.tasks = tasks
    }

    func update(_ progress: InstallProgress) {
        guard state == .running else { return }
        if progress.step != step {
            step = min(max(progress.step, 1), max(tasks.count, 1))
            stepStartedAt = Date()
        }
        let title = tasks.first { $0.id == step }?.title
        detail = progress.message == title ? nil : progress.message
    }

    func finish(_ state: State) {
        guard self.state == .running else { return }
        self.state = state
        isConfirmingCancel = false
    }

    func cancel() {
        isConfirmingCancel = false
        cancellation.cancel()
    }

    var isRunning: Bool { state == .running }
}

/// The install window: opened when an install starts, it lists every step and checks them off,
/// so a long install (a .NET Framework component can take half an hour or more, with nothing
/// on screen) never looks stuck. Closing it doesn't stop the install; Cancel does.
@MainActor
final class InstallProgressWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private static var open: [InstallProgressWindow] = []

    static func show(_ session: InstallSession) {
        let controller = InstallProgressWindow()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Installing \(session.title)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 360)
        let hosting = NSHostingView(rootView: InstallProgressView(session: session) { [weak controller] in controller?.close() })
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 520, height: 520))
        window.delegate = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        controller.window = window
        open.append(controller)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        Self.open.removeAll { $0 === self }
    }
}

private struct InstallProgressView: View {
    @Bindable var session: InstallSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(session.tasks) { task in
                            row(task)
                                .id(task.id)
                            if task.id != session.tasks.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: session.step) { _, step in
                    withAnimation { proxy.scrollTo(step, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(session.step, anchor: .center) }
            }
            Divider()
            footer
                .padding(14)
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.title3.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(subtitle(now: context.date))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headline: String {
        switch session.state {
        case .running: return "Installing \(session.title)"
        case .installed: return "\(session.title) is installed"
        case .failed: return "\(session.title) didn't install"
        case .cancelled: return "The install was cancelled"
        }
    }

    private func subtitle(now: Date) -> String {
        switch session.state {
        case .running:
            return "Step \(session.step) of \(session.tasks.count) · \(Self.duration(now.timeIntervalSince(session.startedAt))) so far"
        case .installed:
            return "It's in your library, ready to play."
        case .failed(let reason):
            return reason
        case .cancelled:
            return "Its bottle was removed."
        }
    }

    @ViewBuilder private func row(_ task: InstallTask) -> some View {
        let isCurrent = task.id == session.step && session.state != .installed
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon(for: task)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isPending(task) ? .secondary : .primary)
                if isCurrent, session.isRunning {
                    if let detail = session.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let note = task.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            if isCurrent, session.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.duration(context.date.timeIntervalSince(session.stepStartedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(task.id) of \(session.tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrent && session.isRunning ? Color.accentColor.opacity(0.08) : .clear)
    }

    private func isPending(_ task: InstallTask) -> Bool {
        session.state != .installed && task.id > session.step
    }

    @ViewBuilder private func icon(for task: InstallTask) -> some View {
        if session.state == .installed || task.id < session.step {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if task.id == session.step {
            switch session.state {
            case .running: ProgressView().controlSize(.small)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var footer: some View {
        if session.isRunning, session.isConfirmingCancel {
            HStack {
                Text("Stop the install? Distiller stops what's running in the new bottle and removes it.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Keep Installing") { session.isConfirmingCancel = false }
                    .keyboardShortcut(.cancelAction)
                Button("Stop Install", role: .destructive) { session.cancel() }
            }
        } else if session.isRunning {
            HStack {
                Text("You can keep using Distiller. Closing this window doesn't stop the install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel Install…") { session.isConfirmingCancel = true }
            }
        } else {
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// "45 s", "12 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
