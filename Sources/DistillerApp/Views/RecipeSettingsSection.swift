import SwiftUI
import DistillerCore

/// The recipe settings a player edits in forms, shared by the recipe builder and the workshop.
/// Lists that are free text in the form (arguments, environment, DLL overrides) are parsed
/// and checked by `problems`.
struct RecipeSettings: Equatable {
    var graphics: GraphicsBackend = .d3dmetal
    var windowsVersion = RecipeResolver.defaultWindowsVersion
    var sync: SyncMode = RecipeResolver.defaultSync
    var retina = false
    var winetricks: [String] = []
    var argumentsText = ""
    var environmentText = ""
    var dllOverridesText = ""

    static let windowsVersions = ["win11", "win10", "win81", "win8", "win7", "winxp"]

    init() {}

    init(recipe: Recipe) {
        graphics = recipe.stack.graphics
        sync = recipe.stack.sync ?? RecipeResolver.defaultSync
        windowsVersion = recipe.prefix?.windows ?? RecipeResolver.defaultWindowsVersion
        retina = recipe.prefix?.retina ?? false
        winetricks = recipe.prefix?.winetricks ?? []
        argumentsText = Self.joinArguments(recipe.launch?.args ?? [])
        environmentText = Self.lines(recipe.env ?? [:])
        dllOverridesText = Self.lines(recipe.prefix?.dllOverrides ?? [:])
    }

    // MARK: Tuning options (Performance & display)

    func tuningValue(_ option: TuningOption) -> String? {
        TuningOptions.value(of: option, in: environment)
    }

    /// Sets a curated option by editing its line in the environment text, so other lines and
    /// comments stay as the player wrote them.
    mutating func setTuning(_ option: TuningOption, to value: String?) {
        let updated = TuningOptions.setting(option, to: value, in: environment)
        environmentText = TuningOptions.settingEnvironmentLine(option.envKey, to: updated[option.envKey], in: environmentText)
    }

    /// Adds `defaults` for keys that aren't set yet; returns the ones it added.
    mutating func addDefaults(_ defaults: [String: String]) -> [String: String] {
        var added: [String: String] = [:]
        for (key, value) in defaults.sorted(by: { $0.key < $1.key }) where environment[key] == nil {
            environmentText = TuningOptions.settingEnvironmentLine(key, to: value, in: environmentText)
            added[key] = value
        }
        return added
    }

    /// Removes keys the builder added, unless the player has changed them since.
    mutating func removeDefaults(_ defaults: [String: String]) {
        for (key, value) in defaults where environment[key] == value {
            environmentText = TuningOptions.settingEnvironmentLine(key, to: nil, in: environmentText)
        }
    }

    var arguments: [String] { Self.splitArguments(argumentsText) }
    var environment: [String: String] { Self.pairs(environmentText) }
    var dllOverrides: [String: String] { Self.pairs(dllOverridesText) }

    /// Problems that would make the recipe invalid, in plain language.
    var problems: [String] {
        var result: [String] = []
        for key in environment.keys.sorted() where !RecipePolicy.isAllowedEnvKey(key) {
            result.append("\(key) can't be set by a recipe. Allowed: variables starting with \(RecipePolicy.envAllowedPrefixes.joined(separator: ", ")).")
        }
        do {
            try RecipePolicy.checkDLLOverrides(dllOverrides)
        } catch {
            result.append(error.localizedDescription)
        }
        return result
    }

    func apply(to draft: inout RecipeDraft) {
        draft.graphics = graphics
        draft.windowsVersion = windowsVersion
        draft.sync = sync
        draft.retina = retina
        draft.winetricks = winetricks
        draft.launchArgs = arguments
        draft.env = environment
        draft.dllOverrides = dllOverrides
    }

    func apply(to recipe: inout Recipe) {
        recipe.stack.graphics = graphics
        recipe.stack.sync = sync
        var prefix = recipe.prefix ?? PrefixSpec()
        prefix.windows = windowsVersion
        prefix.retina = retina ? true : nil
        prefix.winetricks = winetricks.isEmpty ? nil : winetricks
        prefix.dllOverrides = dllOverrides.isEmpty ? nil : dllOverrides
        recipe.prefix = prefix
        recipe.env = environment.isEmpty ? nil : environment
        if recipe.launch != nil {
            recipe.launch?.args = arguments.isEmpty ? nil : arguments
        }
    }

    // MARK: Text forms

    /// Splits on spaces, keeping "quoted parts" together.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if character.isWhitespace && !quoted {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    static func joinArguments(_ arguments: [String]) -> String {
        arguments.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// `KEY=value` lines; blank lines and lines starting with # are ignored.
    static func pairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    static func lines(_ pairs: [String: String]) -> String {
        pairs.keys.sorted().map { "\($0)=\(pairs[$0] ?? "")" }.joined(separator: "\n")
    }
}

/// Form sections for `RecipeSettings`. Put inside a `Form`.
struct RecipeSettingsSections: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: RecipeSettings
    /// Graphics layers that are installed; others are shown but marked.
    let availableGraphics: Set<GraphicsBackend>
    /// Verbs to list first and mark as suggested.
    var suggestedWinetricks: [String] = []
    /// Whether the launch-arguments field applies (it doesn't until a program is chosen).
    var showsArguments = true

    @State private var showsAllVerbs = false

    /// Installed layers the Wine build can't run (D3DMetal and DXMT on WineHQ builds).
    @ViewBuilder private var performanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Retina resolution", isOn: $settings.retina)
                Text("Renders at your display's full pixel density: sharper, but up to four times the pixels, so often much slower. Turn it off first if a game is slow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let options = TuningOptions.options(for: settings.graphics)
            if options.isEmpty {
                Text("No tuning options for \(settings.graphics.displayName) yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(options) { option in
                TuningOptionRow(option: option, settings: $settings)
            }
        } header: {
            Text("Performance & display")
        } footer: {
            Text("Options for \(settings.graphics.displayName). Each is saved as an environment setting in the recipe (under Advanced), so it's shared with the recipe. Settings for other graphics layers are kept but have no effect.")
        }
    }

    private var graphicsProblems: [GraphicsBackend: String] {
        model.engine?.components.graphicsProblems() ?? [:]
    }

    private func graphicsLabel(_ backend: GraphicsBackend) -> String {
        if graphicsProblems[backend] != nil { return "\(backend.displayName) (needs CrossOver-based Wine)" }
        return availableGraphics.contains(backend) ? backend.displayName : "\(backend.displayName) (not installed)"
    }

    var body: some View {
        Section {
            Picker("Graphics", selection: $settings.graphics) {
                ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                    Text(graphicsLabel(backend)).tag(backend)
                }
            }
            Picker("Windows version", selection: $settings.windowsVersion) {
                ForEach(RecipeSettings.windowsVersions, id: \.self) { Text(Self.windowsName($0)).tag($0) }
            }
            Picker("Synchronization", selection: $settings.sync) {
                Text("MSync (fastest)").tag(SyncMode.msync)
                Text("ESync").tag(SyncMode.esync)
                Text("None").tag(SyncMode.none)
            }
        } header: {
            Text("Wine")
        } footer: {
            if let problem = graphicsProblems[settings.graphics] {
                Text(problem).foregroundStyle(.orange)
            } else if !availableGraphics.contains(settings.graphics) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(settings.graphics.displayName) isn't installed, so the game won't start until you add it.")
                        .foregroundStyle(.orange)
                    Spacer()
                    if let item = SetupItem(graphics: settings.graphics) {
                        if item.canInstallAutomatically {
                            Button("Install \(settings.graphics.displayName)") { model.install(item) }
                                .disabled(model.busyMessage != nil)
                        } else {
                            Button("Set Up…") { model.isShowingSetup = true }
                        }
                    }
                }
            }
        }

        performanceSection

        Section {
            let verbs = orderedVerbs
            ForEach(showsAllVerbs ? verbs : collapsedVerbs, id: \.self) { verb in
                Toggle(isOn: binding(for: verb)) {
                    HStack {
                        Text(verb).font(.body.monospaced())
                        if suggestedWinetricks.contains(verb) {
                            Text("Suggested").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(showsAllVerbs ? "Show Fewer" : "Show All \(verbs.count)") { showsAllVerbs.toggle() }
                .buttonStyle(.link)
        } header: {
            Text("Winetricks")
        } footer: {
            Text("Runtime libraries installed into the bottle. Only add what the game needs; each one takes time to install.")
        }

        Section {
            if showsArguments {
                TextField("Launch arguments", text: $settings.argumentsText, prompt: Text("-windowed"))
                    .font(.body.monospaced())
            }
            LabeledContent("Environment") {
                TextEditor(text: $settings.environmentText)
                    .font(.body.monospaced())
                    .frame(minHeight: 52)
            }
            LabeledContent("DLL overrides") {
                TextEditor(text: $settings.dllOverridesText)
                    .font(.body.monospaced())
                    .frame(minHeight: 52)
            }
        } header: {
            Text("Advanced")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("One per line, as NAME=value. For example DXMT_CONFIG=d3d11.preferredMaxFrameRate=60 or d3d9=native.")
                ForEach(settings.problems, id: \.self) { problem in
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
    }

    /// Suggested verbs first, then the rest of the allowlist alphabetically. The order
    /// doesn't change as boxes are ticked, so rows don't jump.
    private var orderedVerbs: [String] {
        let suggested = suggestedWinetricks.filter(RecipePolicy.winetricksVerbs.contains)
        return suggested + RecipePolicy.winetricksVerbs.sorted().filter { !suggested.contains($0) }
    }

    /// Everything suggested or ticked, topped up to eight rows.
    private var collapsedVerbs: [String] {
        let verbs = orderedVerbs
        var shown = verbs.filter { suggestedWinetricks.contains($0) || settings.winetricks.contains($0) }
        for verb in verbs where shown.count < 8 && !shown.contains(verb) {
            shown.append(verb)
        }
        return verbs.filter(shown.contains)
    }

    private func binding(for verb: String) -> Binding<Bool> {
        Binding {
            settings.winetricks.contains(verb)
        } set: { isOn in
            if isOn, !settings.winetricks.contains(verb) {
                settings.winetricks.append(verb)
            } else if !isOn {
                settings.winetricks.removeAll { $0 == verb }
            }
        }
    }

    static func windowsName(_ version: String) -> String {
        switch version {
        case "win11": return "Windows 11"
        case "win10": return "Windows 10"
        case "win81": return "Windows 8.1"
        case "win8": return "Windows 8"
        case "win7": return "Windows 7"
        case "winxp": return "Windows XP"
        default: return version
        }
    }
}


/// One curated setting: its control, what it does, its trade-off, and where it's documented.
private struct TuningOptionRow: View {
    let option: TuningOption
    @Binding var settings: RecipeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch option.control {
            case .toggle(let on):
                Toggle(option.title, isOn: Binding(
                    get: { settings.tuningValue(option) == on },
                    set: { settings.setTuning(option, to: $0 ? on : nil) }
                ))
            case .choice(let choices), .dxmtConfig(_, let choices):
                Picker(option.title, selection: Binding(
                    get: { settings.tuningValue(option) },
                    set: { settings.setTuning(option, to: $0) }
                )) {
                    ForEach(choices, id: \.self) { Text($0.label).tag($0.value) }
                    if let custom = settings.tuningValue(option), !choices.contains(where: { $0.value == custom }) {
                        Text("Custom: \(custom)").tag(Optional(custom))
                    }
                }
            }
            Text(option.explanation).font(.caption).foregroundStyle(.secondary)
            if let tradeoff = option.tradeoff {
                Text("Trade-off: \(tradeoff)").font(.caption).foregroundStyle(.secondary)
            }
            Link("Documentation", destination: option.documentation).font(.caption)
        }
        .padding(.vertical, 2)
    }
}
