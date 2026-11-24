import AppKit
import SwiftUI
import DistillerCore

/// Shown when a recipe being installed names a Wine build Distiller doesn't have: describe
/// where it comes from (a GitHub release), then Distiller downloads it, checks it against
/// GitHub's checksum, completes it with another build's libraries if needed, checks every
/// library it loads is there, and installs it. The source can then be submitted to the
/// community repository so other players' Distiller knows it.
struct AddSourceView: View {
    @Bindable var session: MissingSourceSession
    @State private var fileFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                header
                if session.result == nil {
                    describeSection
                    filesSection
                } else {
                    resultSection
                }
                statusSection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 600, height: 620)
        .interactiveDismissDisabled()
    }

    private var header: some View {
        Section {
            Text("\(session.recipeTitle) needs the Wine build “\(session.missing.tag)”\(session.missing.minVersion.map { " \($0) or later" } ?? ""), which Distiller doesn't have yet.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.missing.source == nil
                 ? "Say where it comes from. Distiller downloads it from its publisher's GitHub releases, checks it against the checksum GitHub publishes, and makes sure it has every library it needs before installing it. You can then share the source, so other players' Distiller knows it too."
                 : "You added a source for it on this Mac. Distiller can download, check and install it now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var describeSection: some View {
        Section("Source") {
            TextField("Name", text: $session.name, prompt: Text("Sikarugir Wine"))
            TextField("GitHub repository", text: $session.repository, prompt: Text("owner/name, such as Sikarugir-App/Engines"))
            TextField("Publisher", text: $session.publisher, prompt: Text("The repository's owner"))
            TextField("Homepage", text: $session.homepage, prompt: Text("https://github.com/owner/name"))
            TextField("Licence", text: $session.license, prompt: Text("SPDX, such as LGPL-2.1-or-later"))
                .help("Wine is LGPL-2.1-or-later; builds of it are too.")
            Picker("Libraries from", selection: $session.librariesFrom) {
                Text("None (it includes everything)").tag(String?.none)
                ForEach(session.libraryDonors, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .help("Some builds leave out common libraries (GStreamer, FFmpeg, GLib) and expect them from elsewhere. Name a Wine build that has them, such as wine-staging; Distiller adds the ones that are missing.")
            TextField("Description", text: $session.summary, prompt: Text("Optional: what it's good for"), axis: .vertical)
                .lineLimit(1...3)
        }
    }

    private var filesSection: some View {
        Section {
            HStack {
                Button("Find Files") { session.findFiles() }
                    .disabled(session.repository.trimmingCharacters(in: .whitespaces).isEmpty || session.isFinding)
                if session.isFinding { ProgressView().controlSize(.small) }
                Spacer()
                if !session.files.isEmpty {
                    Text("\(session.matchingFiles.count) of \(session.files.count) match").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !session.files.isEmpty {
                TextField("Filter", text: $fileFilter, prompt: Text("Show files containing…"))
                FileChooser(session: session, filter: fileFilter)
            }
            TextField("File pattern", text: $session.assetPattern, prompt: Text("Choose a file to fill this in"))
                .font(.callout.monospaced())
                .help("Matches the files to download; the part in parentheses is the version. Updates follow the newest file it matches.")
            if let file = session.selectedFile, let version = session.source.version(of: file.name) {
                Text("Installs \(file.name) (version \(version)). Later updates follow the newest file the pattern matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Download")
        } footer: {
            Text("Choose the file to install now. Files without a checksum from GitHub can't be checked, so Distiller won't install them.")
        }
    }

    @ViewBuilder private var resultSection: some View {
        if let result = session.result {
            Section("Installed \(result.component.manifest.displayName)") {
                Label("Downloaded \(result.file.name) and matched GitHub's checksum", systemImage: "checkmark.seal")
                if let from = result.librariesFrom {
                    Label("Added \(result.librariesAdded) libraries from \(from); every library it loads is there", systemImage: "checkmark.circle")
                } else {
                    Label("Every library it loads is in its download", systemImage: "checkmark.circle")
                }
                if result.containsD3DMetal {
                    Label("Includes D3DMetal. Its publisher answers for it under Apple's terms; the shared source says so.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Doesn't include D3DMetal", systemImage: "checkmark.circle")
                }
                switch result.exportsMacDriverFunctions {
                case true?: Label("Can run D3DMetal and DXMT", systemImage: "checkmark.circle")
                case false?: Label("Can't run D3DMetal or DXMT (DXVK and WineD3D work)", systemImage: "info.circle")
                case nil: EmptyView()
                }
            }
            Section {
                if let url = session.pullRequest {
                    Link("Submitted: \(url.absoluteString)", destination: url)
                } else if session.canSubmit {
                    Button("Submit Source to the Community…") { session.submit() }
                        .disabled(session.isWorking)
                    Text("Opens a pull request adding components/\(session.missing.kind.rawValue)/\(session.missing.tag).yaml to the community repository. A maintainer reviews it before other players' Distiller uses it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sign in with GitHub (in the toolbar) to share this source with other players. It's saved on this Mac either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Share")
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if session.isWorking || session.error != nil || (session.result == nil && !session.problems.isEmpty && !session.repository.isEmpty) {
            Section {
                if session.isWorking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(session.progress ?? "Working…")
                    }
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.result == nil, !session.isWorking {
                    ForEach(session.problems, id: \.self) { problem in
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { session.done(false) }
                .disabled(session.isWorking)
            Spacer()
            if session.result == nil {
                Button("Download, Check and Install") { session.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isWorking || !session.problems.isEmpty
                              || (session.selectedFile == nil && session.missing.source == nil)
                              || session.selectedFile.map { $0.sha256 == nil } == true)
            } else {
                Button("Continue Installing \(session.recipeTitle)") { session.done(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isWorking)
            }
        }
        .padding(16)
    }
}

/// The release files, most recently uploaded first, in a scrolling box of their own (a list
/// nested in a form doesn't scroll on macOS). A check marks files the pattern matches; the
/// chosen one is highlighted.
private struct FileChooser: View {
    @Bindable var session: MissingSourceSession
    let filter: String

    private var shown: [ReleaseFile] {
        let words = filter.lowercased().split(separator: " ")
        return session.files.filter { file in words.allSatisfy { file.name.lowercased().contains($0) } }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { file in
                    row(file)
                }
                if shown.isEmpty {
                    Text("No file names contain “\(filter)”.").font(.callout).foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .frame(height: 230)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func row(_ file: ReleaseFile) -> some View {
        let matches = session.source.version(of: file.name) != nil
        let chosen = session.selectedFileID == file.id
        return Button {
            session.choose(file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: matches ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(matches ? Color.green : Color.secondary)
                Text(file.name).lineLimit(1)
                Spacer()
                if file.sha256 == nil {
                    Text("no checksum").font(.caption).foregroundStyle(.orange)
                }
                Text(file.uploaded.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Text(file.size.map { "\($0 / 1_048_576) MB" } ?? "")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(chosen ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(file.sha256 == nil ? "GitHub publishes no checksum for this file, so Distiller can't install it" : file.name)
    }
}
