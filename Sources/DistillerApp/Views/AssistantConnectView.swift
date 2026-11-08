import AppKit
import SwiftUI
import DistillerCore

/// The "Connect an AI Assistant" window: opens when the player turns the assistant on, and from
/// Settings ▸ AI Assistant. Explains what the assistant can read and how to connect Claude,
/// ChatGPT, LM Studio, Ollama or any other MCP client to `distiller mcp`, with this Mac's path.
struct AssistantConnectView: View {
    static let windowID = "assistant-connect"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var client: MCPClient = .claudeDesktop

    private var setup: MCPClientSetup {
        MCPClientSetup(serverPath: model.bundledServer?.path ?? MCPClientSetup.defaultServerPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !model.assistantEnabled { offNotice }
                    serverRow
                    Picker("Assistant", selection: $client) {
                        ForEach(MCPClient.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    clientSection
                    tryIt
                    whatItReads
                }
                .padding(20)
            }
            Divider()
            HStack {
                Link("Read the guide online", destination: MCPClientSetup.docsURL)
                    .font(.callout)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 480, idealHeight: 640)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect an AI Assistant").font(.title2.bold())
                Text("Distiller includes an MCP (Model Context Protocol) server. Add it to your AI app and the app can read a game's setup, launch logs, crash dumps and program details, then suggest recipe settings to try. It can't change, run or delete anything. Distiller doesn't change your AI app's settings; the steps below show where to add it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var offNotice: some View {
        HStack {
            Label("The assistant is off, so connected assistants see no tools.", systemImage: "exclamationmark.triangle")
            Spacer()
            Button("Turn On") { model.setAssistantEnabled(true) }
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server command").font(.headline)
            HStack {
                Text("\(setup.serverPath) mcp")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                CopyButton(text: "\(setup.serverPath) mcp")
            }
            if model.bundledServer == nil {
                Text("This copy of Distiller isn't running from an app bundle, so the path shown is where an installed app keeps the command. Build the bundle with Scripts/bundle-app.sh, or use the path to your distiller command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("It speaks MCP over standard input and output (stdio): your assistant starts it when needed. Nothing listens on the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var clientSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(setup.steps(for: client).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            ForEach(setup.snippets(for: client), id: \.text) { SnippetView(snippet: $0) }
            Label(client.runsLocally
                  ? "The model runs on this Mac, so what the tools return stays here."
                  : "\(client.name) sends what the tools return (log lines, file contents, your Mac's setup) to its service. Paths in your home folder are shown as ~.",
                  systemImage: client.runsLocally ? "lock.laptopcomputer" : "icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try asking").font(.headline)
            SnippetView(snippet: .init(label: "Prompt", language: "Text", text: MCPClientSetup.examplePrompt))
            Text("Then change the suggested settings in the recipe workshop, launch again and ask it to compare the new log with the last one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatItReads: some View {
        DisclosureGroup("What the assistant can read") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AssistantTools.definitions, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(tool.title) (\(tool.name))").font(.callout.bold())
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Every tool only reads, and only inside a game's own folder and bottle. Responses are text and size-capped. Turn the assistant off in Settings and connected assistants lose access at once.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }
}

/// A block of configuration with its label and a Copy button.
private struct SnippetView: View {
    let snippet: MCPClientSetup.Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(snippet.label).font(.caption.bold())
                Text(snippet.language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: snippet.text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if snippet.language == "Text" {
                body(of: snippet).fixedSize(horizontal: false, vertical: true)
            } else {
                // Configuration keeps its lines; long ones scroll sideways.
                ScrollView(.horizontal) { body(of: snippet).fixedSize() }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func body(of snippet: MCPClientSetup.Snippet) -> some View {
        Text(snippet.text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Copies text to the clipboard, and says so for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
    }
}
