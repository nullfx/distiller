import AppKit
import SwiftUI
import DistillerCommunity
import DistillerCore

/// Sends an authored recipe to the community repository as a pull request from the player's
/// fork. Maintainers review it and the Validate check runs; once merged it appears in Community.
struct SubmitRecipeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: String

    @State private var includeReport = true
    @State private var tier: PlayabilityTier = .gold
    @State private var fpsText = ""
    @State private var reportNotes = ""
    @State private var confirmsOwnership = false
    @State private var confirmsLicense = false
    @State private var isSubmitting = false
    @State private var status: SubmissionStatus?
    @State private var target: SubmissionTarget?
    @State private var targetProblem: String?
    @State private var details = GameDetails(slug: "", title: "")
    @State private var yearText = ""
    @State private var includeIcon = true

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        VStack(spacing: 0) {
            if let game {
                form(game)
                Divider()
                footer(game)
            } else {
                ContentUnavailableView("This game is no longer in the library", systemImage: "questionmark.folder")
            }
        }
        .frame(width: 600, height: 720)
        .task {
            if let game { details = GameDetails(from: CommunityCheck.recipeToSubmit(for: game) ?? game.recipe) }
            await refreshStatus()
            await refreshTarget()
        }
        .onChange(of: model.githubLogin) { Task { await refreshTarget() } }
    }

    private func form(_ game: Game) -> some View {
        let issues = model.submissionIssues(for: game)
        return Form {
            if let submission = game.submission {
                Section("Submitted") {
                    LabeledContent("Pull request") {
                        Link("#\(submission.pullRequest)", destination: URL(string: submission.url) ?? model.repository.webURL)
                    }
                    Text(status?.summary ?? "Checking its status…").foregroundStyle(.secondary)
                    Button("Check Again") { Task { await refreshStatus() } }
                        .buttonStyle(.link)
                }
            }

            Section {
                if let login = model.githubLogin {
                    LabeledContent("Signed in as", value: login)
                    Button("Sign Out") { model.signOutOfGitHub() }
                        .buttonStyle(.link)
                } else {
                    GitHubSignInPanel()
                }
            } header: {
                Text("GitHub account")
            } footer: {
                Text("Distiller asks GitHub for access to public repositories, so it can make a branch for your recipe (in a copy of \(model.repository.fullName) on your account, or in the repository itself if you maintain it) and open a pull request. The token is kept in your keychain.")
            }

            CommunityCheckSection(game: game)
            destinationSection
            if target?.gameExists == false {
                gameDetailsSection
            }
            if CommunityCheck.isCurrent(game) {
                picturesSection(game)
            }

            Section("Checks") {
                if issues.isEmpty {
                    Label("Ready to submit", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                }
            }

            Section {
                Toggle("Include a report of how it ran on this Mac", isOn: $includeReport)
                if includeReport {
                    Picker("How did it run?", selection: $tier) {
                        ForEach(PlayabilityTier.allCases) { tier in
                            Text("\(tier.displayName): \(tier.explanation)").tag(tier)
                        }
                    }
                    TextField("Average FPS (optional)", text: $fpsText)
                    TextField("Notes about this Mac (optional)", text: $reportNotes, axis: .vertical)
                        .lineLimit(2...4)
                }
            } header: {
                Text("Compatibility report")
            } footer: {
                if let hardware = model.hardware {
                    Text("The report includes \(hardware.summary), and nothing else about you.")
                }
            }

            Section {
                Toggle("This recipe only downloads the publisher's official installer", isOn: $confirmsOwnership)
                Toggle("I license this contribution under the repository's MIT license", isOn: $confirmsLicense)
            }
        }
        .formStyle(.grouped)
        .disabled(isSubmitting)
    }

    private func footer(_ game: Game) -> some View {
        let blocked = model.submissionIssues(for: game).contains { $0.severity == .error }
            || (target?.recipeExists == true && target?.canRevise == false)
            || (target?.gameExists == false && !details.problems.isEmpty)
        let isUpdate = game.submission != nil && status?.state == .open
        return HStack {
            Link("View Repository", destination: model.repository.webURL)
            if isSubmitting, let message = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(message).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isUpdate ? "Submit Update" : "Submit Recipe") { submit(game) }
                .keyboardShortcut(.defaultAction)
                .disabled(blocked || model.githubLogin == nil || !confirmsOwnership || !confirmsLicense || isSubmitting)
        }
        .padding(16)
    }

    private func submit(_ game: Game) {
        var report: ReportDraft?
        if includeReport {
            let versions = model.componentVersions(for: game)
            report = ReportDraft(
                tier: tier,
                averageFPS: Double(fpsText.trimmingCharacters(in: .whitespaces)),
                notes: reportNotes,
                wineVersion: versions.wine,
                graphicsVersion: versions.graphics
            )
        }
        isSubmitting = true
        Task {
            details.releaseYear = Int(yearText.trimmingCharacters(in: .whitespaces))
            let succeeded = await model.submit(
                game, report: report, details: target?.gameExists == false ? details : nil,
                includeIcon: includeIcon
            )
            isSubmitting = false
            if succeeded {
                await refreshStatus()
                if let url = model.games.first(where: { $0.id == gameID })?.submission.flatMap({ URL(string: $0.url) }) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func refreshTarget() async {
        guard let game, model.githubLogin != nil else { target = nil; return }
        switch await model.submissionTarget(for: game) {
        case .success(let found):
            target = found
            targetProblem = nil
        case .failure(let error):
            target = nil
            targetProblem = error.localizedDescription
        }
    }

    /// The icon and test-run screenshots from the community check, shown in the catalogue.
    private func picturesSection(_ game: Game) -> some View {
        let pictures = model.communityCheckPictures(for: game)
        let shared = game.communityCheck?.sharedCaptures ?? []
        return Section {
            if pictures.captures.isEmpty {
                Label("The community check didn't capture any screenshots. Run it again and use Capture (or ⌃⌥⌘S) while the game is running. If capturing fails, allow Distiller in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.", systemImage: "camera.metering.unknown")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Screenshots from your test run")
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(pictures.captures, id: \.name) { capture in
                                CaptureTile(url: capture.url, position: shared.firstIndex(of: capture.name))
                                    .onTapGesture { toggle(capture.name, shared: shared, game: game) }
                                    .contextMenu {
                                        Button("Make Cover") {
                                            model.setSharedScreenshots([capture.name] + shared.filter { $0 != capture.name }, for: game)
                                        }
                                        .disabled(shared.first == capture.name)
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Text(shared.isEmpty
                         ? "Click up to \(CommunityMedia.maxSharedScreenshots) screenshots to share them. None are shared now."
                         : "Sharing \(shared.count) of up to \(CommunityMedia.maxSharedScreenshots). Click to add or remove; the first is the cover (right-click another to make it the cover).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let url = pictures.icon, let image = NSImage(contentsOf: url) {
                Toggle(isOn: $includeIcon) {
                    HStack(spacing: 10) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text("Game icon")
                            Text(target?.gameExists == true
                                 ? "Added only if the catalogue doesn't have an icon for this game yet."
                                 : "Read from the installed game's program.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Pictures")
        } footer: {
            Text("Shown with your recipe in the community catalogue and the Community tab. They belong to the game's publisher and are used only to identify the game. Check that nothing personal (account names, chat) is visible.")
        }
    }

    private func toggle(_ name: String, shared: [String], game: Game) {
        if shared.contains(name) {
            model.setSharedScreenshots(shared.filter { $0 != name }, for: game)
        } else if shared.count < CommunityMedia.maxSharedScreenshots {
            model.setSharedScreenshots(shared + [name], for: game)
        } else {
            NSSound.beep()
        }
    }

    /// Where the pull request will come from, and whether it adds or revises a recipe.
    @ViewBuilder private var destinationSection: some View {
        if model.githubLogin != nil {
            Section("Where it goes") {
                if let target {
                    Label(target.isMaintainer
                          ? "You maintain \(model.repository.fullName), so Distiller makes a new branch there for this recipe and opens a pull request from it."
                          : "Distiller copies (forks) \(model.repository.fullName) to your account, makes a branch there for this recipe, and opens a pull request.",
                          systemImage: target.isMaintainer ? "person.badge.shield.checkmark" : "arrow.triangle.branch")
                    if target.recipeExists {
                        Label(target.canRevise
                              ? "The repository already has this recipe, so this is a revision of it."
                              : "The repository already has this recipe by someone else. Give yours a different recipe ID (Edit Recipe), or ask its authors.",
                              systemImage: target.canRevise ? "arrow.triangle.2.circlepath" : "xmark.octagon")
                            .foregroundStyle(target.canRevise ? Color.primary : Color.red)
                    }
                    if !target.gameExists {
                        Label("This is the first recipe for this game, so its catalogue entry is added too.", systemImage: "plus.square.on.square")
                    }
                } else if let targetProblem {
                    Label(targetProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text("Checking the repository…").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The game's catalogue entry, needed when the repository doesn't have the game yet.
    private var gameDetailsSection: some View {
        Section {
            TextField("Publisher", text: Binding(get: { details.publisher ?? "" }, set: { details.publisher = $0 }))
            TextField("Developer", text: Binding(get: { details.developer ?? "" }, set: { details.developer = $0 }), prompt: Text("Optional"))
            TextField("Release year", text: $yearText, prompt: Text("Optional, such as 2012"))
            TextField("Website", text: Binding(get: { details.website ?? "" }, set: { details.website = $0 }), prompt: Text("Optional, https://…"))
            LabeledContent("Description") {
                TextEditor(text: $details.description).frame(minHeight: 70)
            }
            LabeledContent("Genres") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(GameDetails.genres, id: \.self) { genre in
                        Toggle(genre, isOn: Binding(
                            get: { details.genres.contains(genre) },
                            set: { on in
                                if on { details.genres.append(genre) } else { details.genres.removeAll { $0 == genre } }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            ForEach(details.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Game details")
        } footer: {
            Text("This is the first recipe for \(details.title), so the catalogue needs its details. Write the description in your own words; don't copy the publisher's text.")
        }
    }

    private func refreshStatus() async {
        guard let submission = game?.submission else { return }
        status = await model.submissionStatus(for: submission)
    }
}


/// The community check: proof that the shareable recipe installs from the official installer
/// and runs, which submitting requires.
private struct CommunityCheckSection: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        Section {
            if let check = game.communityCheck {
                let current = CommunityCheck.isCurrent(game)
                Label(current ? "Passed \(check.checkedAt.formatted(date: .abbreviated, time: .shortened))" : "Out of date: the recipe changed since it passed",
                      systemImage: current ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(current ? .green : .orange)
                if let exe = check.recipe.launch?.exe {
                    LabeledContent("Installs and launches", value: exe)
                }
                LabeledContent("Tested on", value: "\(check.hardwareKey), \(check.wine)\(check.graphics.map { " + \($0)" } ?? "")")
            } else {
                Text("Not run yet.").foregroundStyle(.secondary)
            }
            Button(game.communityCheck == nil ? "Run Community Check…" : "Run Again…") { model.runCommunityCheck(for: game) }
                .disabled(game.recipe.game.installer == nil || model.busyMessage != nil)
        } header: {
            Text("Community check")
        } footer: {
            Text(game.recipe.game.installer == nil
                 ? "Add the game's official installer link (Edit Recipe ▸ Settings ▸ Official installer) first."
                 : "In a new bottle, Distiller downloads \(URL(string: game.recipe.game.installer?.url ?? "")?.lastPathComponent ?? "the installer") from the publisher, applies this recipe's settings, runs the installer, starts the game, and asks you whether it reached its login or menu. The test bottle is removed afterwards. Large games can take a while.")
        }
    }
}

/// One capture in the Submit window's filmstrip, numbered when it's shared (1 is the cover).
private struct CaptureTile: View {
    let url: URL
    let position: Int?

    var body: some View {
        let image = NSImage(contentsOf: url)
        ZStack(alignment: .topLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(position != nil ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: position != nil ? 3 : 1)
            }
            .opacity(position != nil ? 1 : 0.6)
            if let position {
                Text(position == 0 ? "Cover" : "\(position + 1)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .help(position == nil ? "Click to share this screenshot" : "Click to stop sharing this screenshot")
    }
}
