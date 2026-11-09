import SwiftUI
import DistillerCommunity
import DistillerCore

/// Where an authored recipe is tested and tuned: pick the program to launch, adjust settings,
/// edit the YAML directly, run installers and Wine tools in the bottle, play, and submit.
struct RecipeWorkshopView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let gameID: String

    private enum Tab: String, CaseIterable, Identifiable {
        case settings = "Settings"
        case file = "Recipe File"
        case bottle = "Bottle"
        var id: Self { self }
    }

    @State private var tab: Tab = .settings
    @State private var settings = RecipeSettings()
    @State private var title = ""
    @State private var recipeName = ""
    @State private var notes = ""
    @State private var installerURL = ""
    @State private var installerArgs = ""
    @State private var installerPage = ""
    @State private var launchPath = ""
    @State private var programs: [ProgramInBottle] = []
    @State private var yaml = ""
    @State private var loadedRecipe: Recipe?
    @State private var isSubmitting = false

    private var game: Game? { model.games.first { $0.id == gameID } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            if let game {
                switch tab {
                case .settings: settingsTab(game)
                case .file: fileTab(game)
                case .bottle: bottleTab(game)
                }
                Divider()
                footer(game)
            } else {
                ContentUnavailableView("This game is no longer in the library", systemImage: "questionmark.folder")
            }
        }
        .frame(width: 680, height: 640)
        .onAppear(perform: loadFromGame)
        .onChange(of: game?.recipe) { loadFromGame() }
        .task { await refreshPrograms() }
        .sheet(isPresented: $isSubmitting) {
            SubmitRecipeView(gameID: gameID)
        }
    }

    // MARK: Tabs

    private func settingsTab(_ game: Game) -> some View {
        Form {
            Section {
                Picker("Program", selection: $launchPath) {
                    Text("Not chosen").tag("")
                    if !launchPath.isEmpty && !programs.contains(where: { $0.windowsPath == launchPath }) {
                        Text(launchPath).tag(launchPath)
                    }
                    ForEach(programs, id: \.windowsPath) { entry in
                        Text(entry.windowsPath).tag(entry.windowsPath)
                    }
                }
                Button("Look for Programs Again") { Task { await refreshPrograms() } }
                    .buttonStyle(.link)
            } header: {
                Text("Program to launch")
            } footer: {
                if launchPath.isEmpty {
                    Text("Choose the game's .exe. If it isn't listed, run its installer from the Bottle tab first.")
                }
            }
            Section("Details") {
                TextField("Game title", text: $title)
                TextField("Recipe name", text: $recipeName, prompt: Text("Optional"))
                LabeledContent("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            Section {
                TextField("Download link", text: $installerURL, prompt: Text("https://…"))
                TextField("Download page", text: $installerPage, prompt: Text("Optional: the publisher's page with the download, https://…"))
                TextField("Installer arguments", text: $installerArgs, prompt: Text("Optional, such as /S for a silent install"))
            } header: {
                Text("Official installer")
            } footer: {
                Text("The publisher's own download, never a copy hosted elsewhere. Shared recipes install from it, and the community check proves that works before you submit.")
            }
            RecipeSettingsSections(
                settings: $settings,
                availableGraphics: model.availableGraphics,
                showsArguments: !launchPath.isEmpty
            )
        }
        .formStyle(.grouped)
    }

    private func fileTab(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $yaml)
                .font(.body.monospaced())
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Group {
                if let problem = yamlProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else {
                    Label("Valid recipe", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            .font(.callout)
            .lineLimit(3)
            HStack {
                Button("Open in Editor") { model.openRecipeFile(for: game) }
                    .help("Opens recipe.yaml from the bottle in your YAML editor")
                Button("Reload from File") { model.reloadRecipeFile(for: game) }
                Button("Export…") { model.exportRecipe(for: game) }
                Spacer()
                Button("Revert") { yaml = (try? RecipeLoader.encode(game.recipe)) ?? "" }
                Button("Save YAML") { saveYAML(game) }
                    .disabled(yamlProblem != nil)
            }
        }
        .padding(16)
    }

    private func bottleTab(_ game: Game) -> some View {
        Form {
            Section {
                Button("Run Installer…") { model.runInstaller(for: game) }
            } header: {
                Text("Install")
            } footer: {
                Text("Runs a Windows installer in this bottle and adds it to the recipe, so other players run the same installer.")
            }
            Section("Wine tools") {
                ForEach(WineTool.allCases, id: \.self) { tool in
                    Button(tool.displayName) { model.runTool(tool, for: game) }
                }
            }
            Section {
                Button("Show C: Drive in Finder") { model.revealDriveC(of: game) }
                Button("Show Log") { model.showLog(for: game) }
                Button("Apply Settings to Bottle Again") {
                    Task { _ = await model.save(game.recipe, for: game, forceReconfigure: true) }
                }
            } header: {
                Text("Bottle")
            } footer: {
                Text("Changes made with Wine tools stay in this bottle only. Put settings other players need into the recipe.")
            }
        }
        .formStyle(.grouped)
    }

    private func footer(_ game: Game) -> some View {
        HStack {
            if model.running[game.id] != nil {
                Button("Stop") { model.stop(game) }
            } else {
                Button("Play") { model.launch(game) }
                    .disabled(game.recipe.launch == nil || isDirty)
                    .help(isDirty ? "Save your changes first" : "Start the game to test the recipe")
            }
            Button("Submit to Community…") {
                isSubmitting = true
            }
            .disabled(isDirty || !model.isSignedInToGitHub)
            .help(model.isSignedInToGitHub ? "Share this recipe as a pull request" : "Sign in with GitHub (in the toolbar or Settings) to submit recipes")
            if let message = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(message).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if tab == .settings {
                Button("Save") { saveSettings(game) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || !settings.problems.isEmpty || model.busyMessage != nil)
            }
        }
        .padding(16)
    }

    // MARK: State

    private var editedRecipe: Recipe? {
        guard var recipe = game?.recipe else { return nil }
        recipe.game.title = title
        recipe.name = recipeName.isEmpty ? nil : recipeName
        recipe.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        let link = installerURL.trimmingCharacters(in: .whitespaces)
        let args = RecipeSettings.splitArguments(installerArgs)
        let page = installerPage.trimmingCharacters(in: .whitespaces)
        recipe.game.installer = link.isEmpty ? nil : PublicInstaller(url: link, page: page.isEmpty ? nil : page, args: args.isEmpty ? nil : args)
        if launchPath.isEmpty {
            recipe.launch = nil
        } else if recipe.launch?.exe != launchPath {
            recipe.launch = LaunchSpec(exe: launchPath, args: recipe.launch?.args)
        }
        settings.apply(to: &recipe)
        return recipe
    }

    /// Compares against the saved recipe put through the same form, so defaults the form
    /// fills in (such as an explicit Windows version) don't count as changes.
    private var isDirty: Bool {
        guard let game, let edited = editedRecipe else { return false }
        var baseline = game.recipe
        RecipeSettings(recipe: game.recipe).apply(to: &baseline)
        return edited != baseline
    }

    private var yamlProblem: String? {
        do {
            _ = try RecipeLoader.decode(yaml: yaml)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func loadFromGame() {
        guard let game else { return }
        let recipe = game.recipe
        guard recipe != loadedRecipe else { return }
        loadedRecipe = recipe
        settings = RecipeSettings(recipe: recipe)
        title = recipe.game.title
        recipeName = recipe.name ?? ""
        notes = recipe.notes ?? ""
        installerURL = recipe.game.installer?.url ?? ""
        installerPage = recipe.game.installer?.page ?? ""
        installerArgs = RecipeSettings.joinArguments(recipe.game.installer?.args ?? [])
        launchPath = recipe.launch?.exe ?? ""
        yaml = (try? RecipeLoader.encode(recipe)) ?? ""
    }

    private func refreshPrograms() async {
        guard let game else { return }
        programs = await model.programs(for: game)
        if launchPath.isEmpty, game.recipe.launch == nil, let first = programs.first {
            launchPath = first.windowsPath
        }
    }

    private func saveSettings(_ game: Game) {
        guard let recipe = editedRecipe else { return }
        Task { _ = await model.save(recipe, for: game) }
    }

    private func saveYAML(_ game: Game) {
        guard let recipe = try? RecipeLoader.decode(yaml: yaml) else { return }
        Task { _ = await model.save(recipe, for: game) }
    }
}
