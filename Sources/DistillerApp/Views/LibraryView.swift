import AppKit
import SwiftUI
import DistillerCommunity
import DistillerCore

/// How the library shows games. Remembered between launches.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case list, icons
    var id: Self { self }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .list

    var body: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Create a recipe for a game you have, add one from a recipe file, or pick one other players have shared in Community.")
                } actions: {
                    Button("Create Recipe…") { model.isCreatingRecipe = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add from Recipe File…") { model.isImportingRecipe = true }
                }
            } else if layout == .icons {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 22) {
                        ForEach(model.games) { game in
                            GameTile(game: game)
                        }
                    }
                    .padding(20)
                }
            } else {
                List(model.games) { game in
                    GameRow(game: game)
                }
            }
        }
        .navigationTitle("My Library")
        .toolbar {
            Picker("View", selection: $layout) {
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(LibraryLayout.icons)
            }
            .pickerStyle(.segmented)
            .help("Show games as a list or as icons")
            Menu {
                Button("Create Recipe…") { model.isCreatingRecipe = true }
                Button("Add from Recipe File…") { model.isImportingRecipe = true }
            } label: {
                Label("Add Game", systemImage: "plus")
            }
            .help("Create a recipe or add a game from a recipe file")
        }
    }
}

/// What a game's row or tile shows and allows, shared by both library layouts.
private struct GameState {
    let isRunning: Bool
    let needsSetup: Bool
    /// Why it can't be played now, if it can't.
    let unavailable: String?

    @MainActor init(_ game: Game, model: AppModel) {
        isRunning = model.running[game.id] != nil
        needsSetup = game.recipe.launch == nil
        unavailable = isRunning ? nil : model.availability(of: game).reason
    }

    var canPlay: Bool { !isRunning && !needsSetup && unavailable == nil }
}

/// Play, Stop or Finish Setup, as fits the game's state.
private struct GamePrimaryButton: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let state: GameState

    var body: some View {
        if state.isRunning {
            Button("Stop") { model.stop(game) }
        } else if state.needsSetup {
            Button("Finish Setup…") { model.gameInWorkshop = game }
                .help("Choose the program to launch")
        } else {
            Button("Play") { model.launch(game) }
                .buttonStyle(.borderedProminent)
                .disabled(state.unavailable != nil)
                .help(state.unavailable ?? "Start \(game.title)")
        }
    }
}

/// The right-click menu, and double-click to play, for both layouts.
private struct GameInteractions: ViewModifier {
    @Environment(AppModel.self) private var model
    let game: Game
    let state: GameState

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if state.canPlay { model.launch(game) }
            }
            .contextMenu {
                if state.canPlay {
                    Button("Play") { model.launch(game) }
                    Divider()
                }
                Button("Choose Icon…") { model.chooseIcon(for: game) }
                if model.engine?.hasCustomIcon(game) == true {
                    Button("Use the Program's Icon") { model.useProgramIcon(for: game) }
                }
                Divider()
                Button("Edit Recipe…") { model.gameInWorkshop = game }
                // Browsing and installing work signed out; submitting needs a GitHub account.
                Button(model.isSignedInToGitHub ? "Submit to Community…" : "Submit to Community… (Sign In with GitHub First)") {
                    model.gameToSubmit = game
                }
                .disabled(!model.isSignedInToGitHub)
                if game.isAuthored {
                    Toggle("Just for Me", isOn: Binding(
                        get: { game.isJustForMe },
                        set: { model.setJustForMe($0, for: game) }
                    ))
                    .help("Don't suggest sharing this recipe with the community")
                }
                Divider()
                Button("Show Log") { model.showLog(for: game) }
                Button("Show Bottle in Finder") { model.revealBottle(id: game.bottleID) }
                Button("Report How It Ran…") { model.gameToReport = game }
                Divider()
                Button("Remove from Library…", role: .destructive) { model.removeGame(game) }
            }
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let state = GameState(game, model: model)
        let resolved = model.resolved(game)
        HStack(alignment: .center, spacing: 14) {
            GameIcon(image: model.icons[game.id])
                .opacity(state.unavailable == nil ? 1 : 0.45)
                .saturation(state.unavailable == nil ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(game.title)
                        .font(.headline)
                        .foregroundStyle(state.unavailable == nil ? .primary : .secondary)
                    CommunityBadge(game: game)
                }
                Text(details(resolved))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let unavailable = state.unavailable {
                    Label(unavailable, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let notes = resolved?.appliedOverlayNotes, !notes.isEmpty {
                    Text("Tuned for this Mac: \(notes.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            GamePrimaryButton(game: game, state: state)
        }
        .padding(.vertical, 6)
        .modifier(GameInteractions(game: game, state: state))
    }

    private func details(_ resolved: ResolvedRecipe?) -> String {
        var parts: [String] = []
        if let resolved { parts.append(resolved.graphics.displayName) }
        if let name = game.recipe.name { parts.append(name) }
        if let community = communityDescription { parts.append(community) }
        if let last = game.lastPlayedAt {
            parts.append("Last played \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("Not played yet")
        }
        return parts.joined(separator: " · ")
    }

    private var communityDescription: String? {
        guard game.isAuthored else { return nil }
        let status = model.communityStatus(for: game)
        if game.isJustForMe, status != .published, status != .inReview { return "Your recipe, just for you" }
        switch status {
        case .notAuthored: return nil
        case .unknown: return game.submission.map { "Submitted as pull request #\($0.pullRequest)" } ?? "Your recipe"
        case .newGame: return "Your recipe · not in the community catalogue yet"
        case .newRecipe: return "Your recipe · new to the community catalogue"
        case .changed: return "Your recipe · changed since it was published"
        case .inReview: return game.submission.map { "Submitted as pull request #\($0.pullRequest)" } ?? "Submitted"
        case .published: return "Published in the community catalogue"
        }
    }
}

/// A small share button on games the community catalogue doesn't have (or has differently),
/// unless the player keeps the recipe just for themselves.
private struct CommunityBadge: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if model.suggestsSharing(game) {
            Button {
                model.gameToSubmit = game
            } label: {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!model.isSignedInToGitHub)
            .help(help)
            .accessibilityLabel("Submit \(game.title) to the community")
        }
    }

    private var help: String {
        let reason: String
        switch model.communityStatus(for: game) {
        case .newGame: reason = "The community catalogue doesn't have this game yet."
        case .newRecipe: reason = "The community catalogue doesn't have this recipe for the game."
        case .changed: reason = "Your recipe differs from the one in the community catalogue."
        default: reason = ""
        }
        let action = model.isSignedInToGitHub
            ? "Click to submit it."
            : "Sign in with GitHub (in the toolbar) to submit it."
        return "\(reason) \(action) To stop suggesting it, choose Just for Me from the game's menu."
    }
}

/// A game in the icon layout: a large icon, the title, and its Play button.
struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let state = GameState(game, model: model)
        VStack(spacing: 8) {
            GameIcon(image: model.icons[game.id], size: 96)
                .opacity(state.unavailable == nil ? 1 : 0.45)
                .saturation(state.unavailable == nil ? 1 : 0)
                .overlay(alignment: .bottomTrailing) {
                    if state.isRunning {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .green)
                            .offset(x: 6, y: 6)
                    } else if state.unavailable != nil {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .offset(x: 6, y: 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    CommunityBadge(game: game)
                        .font(.title3)
                        .offset(x: 6, y: -6)
                }
                .help(state.unavailable ?? (state.canPlay ? "Double-click to play" : game.title))
            Text(game.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(state.unavailable == nil ? .primary : .secondary)
            GamePrimaryButton(game: game, state: state)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        .modifier(GameInteractions(game: game, state: state))
    }
}

/// A game's icon, or a placeholder while there is none.
struct GameIcon: View {
    let image: NSImage?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game

    @State private var tier: PlayabilityTier = .gold
    @State private var fpsText = ""
    @State private var notes = ""

    var body: some View {
        Form {
            Section {
                Picker("How did it run?", selection: $tier) {
                    ForEach(PlayabilityTier.allCases) { tier in
                        Text("\(tier.displayName): \(tier.explanation)").tag(tier)
                    }
                }
                TextField("Average FPS (optional)", text: $fpsText)
                TextField("Notes for other players", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Report \(game.title)")
            } footer: {
                Text("This opens a pre-filled form on GitHub. Your report includes your Mac's chip, memory and macOS version, and nothing else about you.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not Now") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Open Report on GitHub") {
                    let fps = Double(fpsText.trimmingCharacters(in: .whitespaces))
                    if let url = model.reportURL(for: game, tier: tier, fps: fps, notes: notes) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
            }
        }
    }
}
