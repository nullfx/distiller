import SwiftUI
import DistillerCore

/// The two movable storage locations, each with its drive and a Change… button.
/// Used in the setup assistant and in Settings.
struct StorageLocationsSection: View {
    @Environment(AppModel.self) private var model
    var header = "Where Distiller keeps things"

    var body: some View {
        Section {
            ForEach(StorageKind.allCases) { kind in
                StorageLocationRow(kind: kind)
            }
        } header: {
            Text(header)
        } footer: {
            Text("The game library, logs and settings stay in Application Support. Games you use in place stay where they are, and each bottle sees their drive as D:, E: and so on.")
        }
    }
}

private struct StorageLocationRow: View {
    @Environment(AppModel.self) private var model
    let kind: StorageKind

    var body: some View {
        let location = model.location(of: kind)
        let missing = model.unavailableStorage.first { $0.kind == kind }
        let volume = location.flatMap { StorageVolume(containing: $0) }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .wine ? "wineglass" : "shippingbox")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).font(.headline)
                Text(kind.purpose).font(.callout).foregroundStyle(.secondary)
                Text(location?.path ?? "…")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let missing {
                    Label(missing.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let volume {
                    Text("\(volume.format) · \(volume.availableDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(volume.warnings, id: \.self) { warning in
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button("Change…") { model.chooseStorageLocation(kind) }
                .disabled(model.busyMessage != nil)
        }
        .padding(.vertical, 4)
    }
}

/// Distiller ▸ Settings… (⌘,): standard toolbar tabs for storage, component updates, the
/// GitHub account and the AI assistant.
struct SettingsView: View {
    var body: some View {
        TabView {
            SettingsPane {
                StorageLocationsSection(header: "Storage")
                LogsSettingsSection()
            }
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            SettingsPane { ComponentUpdateSettingsSection() }
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            SettingsPane { GitHubSettingsSection() }
                .tabItem { Label { Text("GitHub") } icon: { Image(nsImage: .gitHubMarkTemplate) } }
            SettingsPane { AssistantSettingsSection() }
                .tabItem { Label("AI Assistant", systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

/// One Settings tab: a grouped form sized to its content, and the progress of long work
/// (such as moving storage) under it.
private struct SettingsPane<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .scrollDisabled(true)
            if let message = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings ▸ Storage ▸ Logs: how much the logs take, how long and how much to keep.
struct LogsSettingsSection: View {
    @Environment(AppModel.self) private var model
    static let retentionChoices = [3, 7, 14, 30, 90, 0]
    static let limitChoices = [250, 500, 1024, 2048, 5120, 0]

    var body: some View {
        let settings = model.logSettings
        Section {
            LabeledContent("Logs now") {
                if let usage = model.logUsage {
                    Text("\(usage.files) log\(usage.files == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Picker("Keep logs for", selection: Binding(get: { settings.effectiveLogRetentionDays }, set: { model.setLogRetention(days: $0) })) {
                ForEach(Self.retentionChoices, id: \.self) { days in
                    Text(days == 0 ? "Until the size limit" : "\(days) days").tag(days)
                }
            }
            Picker("Keep at most", selection: Binding(get: { settings.effectiveLogLimitMB }, set: { model.setLogLimit(megabytes: $0) })) {
                ForEach(Self.limitChoices, id: \.self) { megabytes in
                    Text(megabytes == 0 ? "No limit" : ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1024 * 1024, countStyle: .file)).tag(megabytes)
                }
            }
            HStack {
                Button("Clean Up Now") { model.cleanUpLogs() }
                    .disabled(model.busyMessage != nil)
                Button("Show in Finder") { model.showLogsFolder() }
                Spacer()
                if let message = model.logCleanupMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Logs")
        } footer: {
            Text("Each launch writes a log, which the troubleshooting assistant reads. Distiller removes old logs, then the oldest over the limit, when it starts and once a day. A game's log keeps its first 20 MB and last 4 MB however much it prints, and logs written in the last hour are always kept.")
        }
        .onAppear { model.refreshLogUsage() }
    }
}

/// Shown across the top of the main window while a storage drive is disconnected.
struct UnavailableStorageBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.unavailableStorage.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.unavailableStorage, id: \.kind) { missing in
                    Label(missing.message, systemImage: "externaldrive.badge.exclamationmark")
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.15))
        }
    }
}


/// Settings ▸ AI Assistant: whether `distiller mcp` serves its troubleshooting tools (off until
/// the player turns it on), and how an AI app connects. Distiller never edits other apps'
/// settings: the player adds the server command to their AI app, which starts it when needed.
struct AssistantSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var serverCommand: String {
        "\(model.bundledServer?.path ?? MCPClientSetup.defaultServerPath) mcp"
    }

    var body: some View {
        Section {
            Toggle("Let AI assistants troubleshoot games", isOn: Binding(
                get: { model.assistantEnabled },
                set: { enabled in
                    let turningOn = enabled && !model.assistantEnabled
                    model.setAssistantEnabled(enabled)
                    if turningOn { openWindow(id: AssistantConnectView.windowID) }
                }
            ))
            Text("When on, an AI app you connect (Claude, ChatGPT, or a model in LM Studio or Ollama) can read your games' setup, recipes, logs and crash dumps to help you build a recipe or fix a game. It can't change anything. Turn it off once your games run and you just want to play; a connected app loses access at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI Assistant")
        }
        Section {
            LabeledContent("Server command") {
                HStack(spacing: 8) {
                    Text(serverCommand)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(text: serverCommand)
                }
            }
            HStack {
                Button("Connection Steps…") { openWindow(id: AssistantConnectView.windowID) }
                Spacer()
                Link("Read the guide online", destination: MCPClientSetup.docsURL)
            }
        } header: {
            Text("Connecting an AI app")
        } footer: {
            Text("Distiller doesn't change other apps' settings. Add the command above to your AI app's MCP servers and the app starts Distiller's server when it needs it. Any app that supports local (stdio) MCP servers can connect.")
        }
    }
}
