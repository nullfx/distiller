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

/// Distiller ▸ Settings… (⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                StorageLocationsSection(header: "Storage")
                GitHubSettingsSection()
                AssistantSettingsSection()
            }
            .formStyle(.grouped)
            if let message = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
/// the player turns it on), the Claude Desktop connection, and the connection guide.
struct AssistantSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

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
            Text("When on, an assistant you connect (Claude, ChatGPT, or a model in LM Studio or Ollama) can read your games' setup, recipes, logs and crash dumps to help you build a recipe or fix a game. It can't change anything. Turn it off once your games run and you just want to play; an assistant that's already connected loses access at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Claude Desktop") {
                HStack {
                    let command = model.claudeDesktopCommand
                    Text(command == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                    if command == nil {
                        Button("Connect") { model.connectClaudeDesktop(true) }
                            .disabled(model.bundledServer == nil)
                    } else {
                        Button("Disconnect") { model.connectClaudeDesktop(false) }
                    }
                }
            }
            LabeledContent("Other assistants") {
                Button("Connection Guide…") { openWindow(id: AssistantConnectView.windowID) }
            }
        } header: {
            Text("AI Assistant")
        } footer: {
            Text("Restart Claude Desktop after connecting or disconnecting. The guide shows the settings for Claude Code, ChatGPT, LM Studio, Ollama and other MCP clients.")
        }
    }
}
