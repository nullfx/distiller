import SwiftUI
import UniformTypeIdentifiers
import DistillerCore

/// The assisted way to make a recipe: pick a game folder, an installer, or an empty bottle;
/// name it; review suggested settings; then Distiller creates the bottle, installs, and opens
/// the workshop to test and fine-tune.
struct RecipeBuilderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case source, details, settings, review

        var title: String {
            switch self {
            case .source: return "What are you adding?"
            case .details: return "Name the game and recipe"
            case .settings: return "Choose how it runs"
            case .review: return "Review and install"
            }
        }
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case folder, installer, manual
        var id: Self { self }

        var title: String {
            switch self {
            case .folder: return "A game already on this Mac"
            case .installer: return "A Windows installer"
            case .manual: return "An empty bottle I'll set up myself"
            }
        }

        var explanation: String {
            switch self {
            case .folder: return "A folder with the game's .exe, for example from GOG, a disc, or a Windows PC. Other players choose their own copy of the folder."
            case .installer: return "A setup .exe or .msi. Distiller runs it in a new bottle, then you pick the program it installed."
            case .manual: return "Create a bottle with your chosen settings, run installers and Wine tools yourself, and edit the recipe file directly. Installers you run from Distiller are added to the recipe."
            }
        }
    }

    private enum Picking { case folder, installer }

    @State private var step: Step = .source
    @State private var kind: SourceKind = .folder
    @State private var folderURL: URL?
    @State private var installerURL: URL?
    @State private var programs: [DiscoveredProgram] = []
    @State private var selectedProgram: String?
    @State private var inspection: GameInspection?
    @State private var extraSuggestions: [String] = []
    @State private var picking: Picking?
    @State private var isPicking = false

    @State private var title = ""
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var recipeID = ""
    @State private var recipeName = ""
    @State private var publisher = ""
    @State private var publicInstaller = ""
    @State private var notes = ""
    @State private var installerArguments = ""
    @State private var settings = RecipeSettings()
    @State private var linkInPlace = false
    /// Settings the builder added for the chosen graphics layer (such as DXVK_ASYNC=1).
    @State private var layerDefaults: [String: String] = [:]
    @State private var folderBytes: Int64?
    @State private var folderVolume: StorageVolume?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch step {
                case .source: sourceStep
                case .details: detailsStep
                case .settings: settingsStep
                case .review: reviewStep
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            .onChange(of: settings.graphics, initial: true) {
                // An ID that just names the graphics layer follows the choice.
                if GraphicsBackend(rawValue: recipeID) != nil { recipeID = settings.graphics.rawValue }
                // Swap the previous layer's defaults (unless changed) for the new layer's.
                settings.removeDefaults(layerDefaults)
                layerDefaults = settings.addDefaults(TuningOptions.builderDefaults(for: settings.graphics))
            }

            Divider()
            HStack {
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if step != .source {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .source }
                }
                if step == .review {
                    Button(isCreating ? "Installing…" : "Create and Install") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isCreating || validationError != nil)
                } else {
                    Button("Continue") { advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: picking == .folder ? [.folder] : [.exe, .msi, .item]) { result in
            guard case .success(let url) = result else { return }
            switch picking {
            case .folder: chooseFolder(url)
            case .installer: chooseInstaller(url)
            case nil: break
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var sourceStep: some View {
        Section {
            Picker("Source", selection: $kind) {
                ForEach(SourceKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(kind)
                    .padding(.vertical, 3)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        } header: {
            Text("What are you adding?")
        }

        switch kind {
        case .folder:
            Section("Game folder") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folderURL?.path ?? "None chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { pick(.folder) }
                    }
                }
                if folderURL != nil {
                    if programs.isEmpty {
                        Text("No Windows programs (.exe) were found in this folder.").foregroundStyle(.secondary)
                    } else {
                        Picker("Program to launch", selection: $selectedProgram) {
                            ForEach(programs) { program in
                                Text("\(program.relativePath)  ·  \(ByteCountFormatter.string(fromByteCount: program.size, countStyle: .file))")
                                    .tag(Optional(program.relativePath))
                            }
                        }
                        .onChange(of: selectedProgram) { inspectSelected() }
                    }
                }
            }
            if folderURL != nil {
                Section {
                    Picker("Game files", selection: $linkInPlace) {
                        Text("Use the folder where it is").tag(true)
                        Text("Copy it into the bottle").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Use or copy")
                } footer: {
                    Text(folderChoiceExplanation)
                        .foregroundStyle(copyDoesNotFit ? .red : .secondary)
                }
            }
        case .installer:
            Section("Installer") {
                LabeledContent("Installer") {
                    HStack {
                        Text(installerURL?.lastPathComponent ?? "None chosen").foregroundStyle(.secondary)
                        Button("Choose…") { pick(.installer) }
                    }
                }
                TextField("Installer arguments", text: $installerArguments, prompt: Text("Optional, such as /S for a silent install"))
            }
        case .manual:
            EmptyView()
        }
    }

    @ViewBuilder private var detailsStep: some View {
        Section {
            TextField("Game title", text: $title)
                .onChange(of: title) {
                    if !slugEdited { slug = RecipeDraft.makeSlug(title) }
                }
            TextField("Game ID", text: Binding(get: { slug }, set: { slug = $0; slugEdited = true }))
                .font(.body.monospaced())
            TextField("Recipe ID", text: $recipeID)
                .font(.body.monospaced())
            TextField("Recipe name", text: $recipeName, prompt: Text("Optional, such as \"D3DMetal, high settings\""))
            TextField("Publisher", text: $publisher, prompt: Text("Optional"))
            TextField("Official installer", text: $publicInstaller, prompt: Text("https://… the publisher's download link (needed to share)"))
        } header: {
            Text("Game")
        } footer: {
            Text("IDs use lowercase letters, digits and hyphens. In the community repository the recipe lives at recipes/\(slug.isEmpty ? "<game-id>" : slug)/\(recipeID.isEmpty ? "<recipe-id>" : recipeID).yaml.")
        }
        Section("Notes for other players") {
            TextEditor(text: $notes)
                .frame(minHeight: 70)
        }
    }

    @ViewBuilder private var settingsStep: some View {
        if let inspection, !inspection.findings.isEmpty {
            Section("What Distiller found") {
                ForEach(inspection.findings, id: \.self) { finding in
                    Label(finding, systemImage: "info.circle")
                }
            }
        }
        RecipeSettingsSections(
            settings: $settings,
            availableGraphics: model.availableGraphics,
            suggestedWinetricks: suggestions,
            showsArguments: kind == .folder
        )
    }

    @ViewBuilder private var reviewStep: some View {
        if kind == .folder {
            Section {
                LabeledContent("Game files", value: linkInPlace ? "Used where they are" : "Copied into the bottle")
            } footer: {
                Text(folderChoiceExplanation)
            }
        }
        Section {
            ScrollView {
                Text(previewYAML)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)
        } header: {
            Text("Recipe")
        } footer: {
            if let validationError {
                Text(validationError).foregroundStyle(.red)
            } else if kind != .folder {
                Text("After installing, you'll choose the program to launch and can test it before saving.")
            }
        }
    }

    // MARK: Logic

    private var suggestions: [String] {
        var verbs = inspection?.suggestedWinetricks ?? []
        for verb in extraSuggestions where !verbs.contains(verb) { verbs.append(verb) }
        return verbs
    }

    private var canContinue: Bool {
        switch step {
        case .source:
            switch kind {
            case .folder: return folderURL != nil && selectedProgram != nil && !copyDoesNotFit
            case .installer: return installerURL != nil
            case .manual: return true
            }
        case .details:
            return !title.trimmingCharacters(in: .whitespaces).isEmpty && RecipePolicy.isValidSlug(slug) && RecipePolicy.isValidSlug(recipeID)
        case .settings:
            return settings.problems.isEmpty
        case .review:
            return false
        }
    }

    private func advance() {
        if step == .source {
            if title.isEmpty { title = suggestedTitle }
            if recipeID.isEmpty { recipeID = settings.graphics.rawValue }
        }
        step = Step(rawValue: step.rawValue + 1) ?? .review
    }

    private var suggestedTitle: String {
        switch kind {
        case .folder: return folderURL?.lastPathComponent ?? ""
        case .installer:
            let name = installerURL?.deletingPathExtension().lastPathComponent ?? ""
            return name.replacingOccurrences(of: "[_-]?(setup|install(er)?)[_-]?", with: " ", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        case .manual: return ""
        }
    }

    private var draft: RecipeDraft {
        let source: RecipeDraft.Source
        switch kind {
        case .folder: source = .folder(folderURL ?? URL(fileURLWithPath: "/"))
        case .installer: source = .installer(installerURL ?? URL(fileURLWithPath: "/setup.exe"))
        case .manual: source = .manual
        }
        var draft = RecipeDraft(source: source, title: title, slug: slug, recipeID: recipeID, runner: model.defaultRunner, graphics: settings.graphics)
        draft.recipeName = recipeName
        draft.publisher = publisher
        draft.publicInstallerURL = publicInstaller.trimmingCharacters(in: .whitespaces)
        draft.notes = notes
        draft.installerArgs = RecipeSettings.splitArguments(installerArguments)
        settings.apply(to: &draft)
        if kind == .folder { draft.launchProgram = selectedProgram }
        return draft
    }

    private var previewYAML: String {
        (try? RecipeLoader.encode(draft.makeRecipe())) ?? ""
    }

    private var validationError: String? {
        do {
            try RecipeLoader.validate(draft.makeRecipe())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func pick(_ what: Picking) {
        picking = what
        isPicking = true
    }

    private func chooseFolder(_ url: URL) {
        folderURL = url
        programs = []
        selectedProgram = nil
        inspection = nil
        folderBytes = nil
        folderVolume = StorageVolume(containing: url)
        // A game on another drive is used where it is by default: copying it costs its full
        // size, and games that update their own data files must keep using the original.
        linkInPlace = folderVolume?.root != model.bottlesVolume?.root
        Task {
            let described = await model.describeFolder(url)
            if folderURL == url { folderBytes = described.bytes }
        }
        Task {
            let found = await model.programs(inFolder: url)
            programs = found
            selectedProgram = found.first?.relativePath
            extraSuggestions = await Task.detached { GameInspector.redistributableHints(in: url) }.value
            inspectSelected()
        }
    }

    private var bottlesVolume: StorageVolume? { model.bottlesVolume }

    private var copyDoesNotFit: Bool {
        guard !linkInPlace, let folderBytes, let bottlesVolume, let available = bottlesVolume.availableBytes,
              folderVolume?.root != bottlesVolume.root else { return false }
        return folderBytes > available
    }

    private var folderChoiceExplanation: String {
        let size = folderBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let sourceDrive = folderVolume?.name ?? "its drive"
        if linkInPlace {
            let drive = folderVolume?.isStartupDisk == false
                ? " The game sees “\(sourceDrive)” as its own drive (D:, or the next free letter)."
                : ""
            return "The bottle uses your folder directly, so the game reads and writes its files there, including any data it updates when it starts.\(drive) Keep the folder where it is, and the drive connected, to play."
        }
        guard let bottlesVolume else { return "The folder is copied into the bottle." }
        if folderVolume?.root == bottlesVolume.root {
            return "The folder is copied into the bottle. On the same drive this is instant and takes no extra space. The game then updates its copy, not your folder."
        }
        let cost = size.map { "Copying uses \($0) on \(bottlesVolume.name)" } ?? "Copying uses the folder's full size on \(bottlesVolume.name)"
        let free = bottlesVolume.availableBytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free)" } ?? ""
        let fit = copyDoesNotFit ? " That's more than is free, so use the folder where it is or move bottles in Settings." : ""
        return "\(cost)\(free), and the game then updates its copy, not your folder.\(fit)"
    }

    private func chooseInstaller(_ url: URL) {
        installerURL = url
        inspection = nil
        title = ""
    }

    private func inspectSelected() {
        guard let program = programs.first(where: { $0.relativePath == selectedProgram }) else { return }
        Task {
            let result = await model.inspect(executable: program.url)
            inspection = result
            settings.graphics = result.suggestedGraphics
            settings.windowsVersion = result.suggestedWindowsVersion
            settings.winetricks = suggestions
        }
    }

    private func create() {
        var supplied = UserSupplied()
        switch kind {
        case .folder:
            if let folderURL { supplied.folders[RecipeDraft.folderStepID] = UserFolderSource(url: folderURL, linkInPlace: linkInPlace) }
        case .installer:
            if let installerURL { supplied.files[RecipeDraft.installerStepID] = installerURL }
        case .manual:
            break
        }
        let draft = self.draft
        // Captured now: the environment isn't readable once this sheet has closed.
        let model = self.model
        isCreating = true
        Task {
            let game = await model.create(from: draft, supplied: supplied)
            isCreating = false
            if let game {
                dismiss()
                // Let this sheet finish closing before the workshop sheet opens.
                try? await Task.sleep(nanoseconds: 400_000_000)
                model.gameInWorkshop = game
            }
        }
    }
}

extension UTType {
    static let msi = UTType(filenameExtension: "msi") ?? .data
}
