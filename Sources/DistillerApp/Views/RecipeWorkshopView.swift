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
    @State private var installerUpdates = false
    @State private var launchPath = ""
    @State private var programs: [ProgramInBottle] = []
    @State private var yaml = ""
    @State private var loadedRecipe: Recipe?
    @State private var isSubmitting = false
    @State private var isCapturingInstaller = false

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
        .sheet(isPresented: $isCapturingInstaller) {
            InstallerCaptureView(startPage: captureStartPage) { url, page in
                installerURL = url?.absoluteString ?? ""
                if let page { installerPage = page.absoluteString }
            }
        }
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
                TextField("Download link", text: $installerURL, prompt: Text("https://…, or empty to download from the page"))
                TextField("Download page", text: $installerPage, prompt: Text("The publisher's page with the download, https://…"))
                TextField("Installer arguments", text: $installerArgs, prompt: Text("Optional, such as /S for a silent install"))
                Toggle("The installer changes with updates", isOn: $installerUpdates)
                    .help("For installers whose file changes with every release, such as a game launcher's: the recipe checks the publisher's signature instead of a fixed checksum.")
                Button("Get from Download Page…") { isCapturingInstaller = true }
                    .help("Open the publisher's download page, download the installer there, and let Distiller find a link players can download it from directly.")
            } header: {
                Text("Official installer")
            } footer: {
                Text("The publisher's own download, never a copy hosted elsewhere. Shared recipes install from it, and the community check proves that works before you submit. If no link works on its own, leave the link empty and give the download page: players then download the installer there, in Distiller's browser. If its file changes with every release (a game launcher's, for example), turn on “changes with updates”: the shared recipe then checks the publisher's signature instead of a fixed checksum.")
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
            RestorePointSection(game: game)
            RebuildSection(game: game)
            GameVersionsSection(game: game)
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

    /// Where the installer browser opens: the recipe's download page, else the game's website.
    private var captureStartPage: URL? {
        for text in [installerPage, game?.recipe.game.website ?? ""] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil { return url }
        }
        return nil
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
        recipe.game.installer = link.isEmpty && page.isEmpty ? nil : PublicInstaller(
            url: link.isEmpty ? nil : link, page: page.isEmpty ? nil : page,
            updates: installerUpdates ? true : nil, args: args.isEmpty ? nil : args)
        if launchPath.isEmpty {
            recipe.launch = nil
        } else if recipe.launch?.exe != launchPath {
            recipe.launch = LaunchSpec(exe: launchPath, args: recipe.launch?.args)
        }
        settings.apply(to: &recipe)
        // The lowest schema that describes it, so older versions of Distiller can still read it.
        recipe.schema = max(Recipe.baseSchema, recipe.requiredSchema)
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
        installerUpdates = recipe.game.installer?.updates == true
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

/// Workshop ▸ Bottle ▸ Versions: whether this game follows the active Wine build, graphics layer
/// and winetricks, or stays on a version. A choice on this Mac only; never part of the recipe.
struct GameVersionsSection: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        // Re-read on every reload, so a choice shows at once.
        let _ = model.components
        if let versions = model.versions(for: game) {
            Section {
                picker("Wine", versions.wine)
                if let graphics = versions.graphics { picker("Graphics layer", graphics) }
                picker("winetricks", versions.winetricks)
            } header: {
                Text("Versions")
            } footer: {
                Text("Staying on a version keeps this game as it is when Distiller updates, but it may miss fixes or stop working with newer recipes. Wine can only stay on the build this game uses now or a newer one: Wine can't move a bottle back.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func picker(_ label: String, _ choice: GameVersions.Choice) -> some View {
        Picker(label, selection: Binding<String?>(
            get: { choice.stayOn },
            set: { model.setStayOn(choice.kind, id: $0, for: game) }
        )) {
            Text("Follow updates (\(choice.active?.manifest.displayName ?? "none installed"))").tag(String?.none)
            if !choice.options.isEmpty { Divider() }
            ForEach(choice.options) { component in
                Text("Stay on \(component.manifest.displayName)").tag(String?.some(component.id))
            }
        }
    }
}

/// Workshop ▸ Bottle ▸ Restore point: the copy of the bottle from before it moved to a newer
/// Wine, with Roll Back and Remove.
struct RestorePointSection: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var isConfirmingRollBack = false

    var body: some View {
        let _ = model.components
        if let point = model.restorePoint(for: game) {
            Section {
                LabeledContent("Saved \(point.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    HStack {
                        Button("Roll Back…") { isConfirmingRollBack = true }
                            .disabled(model.running[game.id] != nil || model.busyMessage != nil)
                        Button("Remove") { model.discardRestorePoint(game) }
                    }
                }
                Text("A copy of this bottle from before it moved from \(RestorePoint.describe(point.fromWine)) to \(RestorePoint.describe(point.toWine)).\(point.confirmedAt == nil ? "" : " You said the game works on the new Wine.")")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Restore point")
            } footer: {
                Text("Roll Back puts the copy back, so anything saved inside the bottle since then is lost, and keeps the game on \(RestorePoint.describe(point.fromWine)). How long restore points are kept is in Settings ▸ Updates.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .confirmationDialog("Roll \(game.title) back to \(RestorePoint.describe(point.fromWine))?", isPresented: $isConfirmingRollBack) {
                Button("Roll Back", role: .destructive) { model.rollBack(game) }
            } message: {
                Text("The bottle goes back to how it was on \(point.createdAt.formatted(date: .abbreviated, time: .shortened)). Changes since then inside the bottle (including saves a game keeps there) are lost.")
            }
        }
    }
}

/// Workshop ▸ Bottle ▸ Rebuild: a new bottle from the recipe with the current components, the
/// last resort when a game won't move to newer ones; then keep it or switch back.
struct RebuildSection: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var isConfirming = false

    var body: some View {
        Section {
            if let rebuild = game.rebuild {
                LabeledContent("Rebuilt \(rebuild.rebuiltAt.formatted(date: .abbreviated, time: .shortened))") {
                    HStack {
                        Button("Switch Back") { model.switchBack(game) }
                            .disabled(model.running[game.id] != nil)
                        Button("Keep New Bottle") { model.keepRebuild(game) }
                    }
                }
                Text("The old bottle is kept until you decide. Keep New Bottle moves it to the Trash; Switch Back returns to it and removes the new one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Rebuild with Current Components…") { isConfirming = true }
                    .disabled(model.running[game.id] != nil || model.busyMessage != nil)
            }
        } header: {
            Text("Rebuild")
        } footer: {
            if game.rebuild == nil {
                Text("Installs the recipe into a new bottle with the active Wine build, graphics layer and winetricks, for when the game doesn't work after moving to newer ones. The old bottle is kept until you decide.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Rebuild \(game.title)'s bottle?", isPresented: $isConfirming) {
            Button("Rebuild") { model.rebuild(game) }
        } message: {
            Text("The recipe is installed again into a new bottle, with the same steps as a fresh install. Files and folders you chose before are reused from the old bottle where possible; anything else is asked for again. Anything the game keeps inside its bottle (saved games under C:\\users, its settings, a launcher's sign-in) isn't carried over: copy it from the old bottle's C: drive if you need it. The old bottle is kept until you decide.")
        }
    }
}
