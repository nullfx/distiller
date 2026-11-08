import Foundation

/// Per-game changes the player made locally. Never uploaded unless they publish a fork.
public struct LocalOverrides: Codable, Equatable, Sendable {
    public var graphics: GraphicsBackend?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    public var args: [String]?

    enum CodingKeys: String, CodingKey {
        case graphics, env, args
        case dllOverrides = "dll_overrides"
    }

    public init(graphics: GraphicsBackend? = nil, env: [String: String]? = nil, dllOverrides: [String: String]? = nil, args: [String]? = nil) {
        self.graphics = graphics
        self.env = env
        self.dllOverrides = dllOverrides
        self.args = args
    }
}

/// A recipe with its overlays and the player's overrides applied for one Mac.
public struct ResolvedRecipe: Codable, Equatable, Sendable {
    public var recipeID: String
    public var gameSlug: String
    public var runner: RunnerRequirement
    public var graphics: GraphicsBackend
    public var sync: SyncMode
    public var windowsVersion: String
    public var retina: Bool
    public var winetricks: [String]
    public var dllOverrides: [String: String]
    public var registry: [RegistryEdit]
    public var env: [String: String]
    public var install: [InstallStep]
    public var launch: LaunchSpec?
    /// Indexes into `recipe.overlays` of the overlays that matched.
    public var appliedOverlays: [Int]
    public var appliedOverlayNotes: [String]
}

public enum RecipeResolver {
    public static let defaultWindowsVersion = "win10"
    public static let defaultSync = SyncMode.msync

    /// Resolution order: built-in defaults, the recipe body, each matching overlay in file
    /// order, then the player's local overrides. Component defaults (layer 2 in the design)
    /// are merged at launch by `WineEnvironment`, because they depend on what's installed.
    public static func resolve(_ recipe: Recipe, for hardware: HardwareProfile, overrides: LocalOverrides? = nil) -> ResolvedRecipe {
        var result = ResolvedRecipe(
            recipeID: recipe.id,
            gameSlug: recipe.game.slug,
            runner: recipe.stack.runner,
            graphics: recipe.stack.graphics,
            sync: recipe.stack.sync ?? defaultSync,
            windowsVersion: recipe.prefix?.windows ?? defaultWindowsVersion,
            retina: recipe.prefix?.retina ?? false,
            winetricks: recipe.prefix?.winetricks ?? [],
            dllOverrides: recipe.prefix?.dllOverrides ?? [:],
            registry: recipe.prefix?.registry ?? [],
            env: recipe.env ?? [:],
            install: recipe.install ?? [],
            launch: recipe.launch,
            appliedOverlays: [],
            appliedOverlayNotes: []
        )

        for (index, overlay) in (recipe.overlays ?? []).enumerated() where OverlayMatcher.matches(overlay.when, hardware) {
            if let stack = overlay.stack {
                if let runner = stack.runner { result.runner = runner }
                if let graphics = stack.graphics { result.graphics = graphics }
                if let sync = stack.sync { result.sync = sync }
            }
            result.env.merge(overlay.env ?? [:]) { _, new in new }
            result.dllOverrides.merge(overlay.dllOverrides ?? [:]) { _, new in new }
            result.registry += overlay.registry ?? []
            if let winetricks = overlay.winetricks { result.winetricks = winetricks }
            for verb in overlay.appendWinetricks ?? [] where !result.winetricks.contains(verb) {
                result.winetricks.append(verb)
            }
            if let args = overlay.args { result.launch?.args = args }
            result.appliedOverlays.append(index)
            if let note = overlay.note { result.appliedOverlayNotes.append(note) }
        }

        if let overrides {
            if let graphics = overrides.graphics { result.graphics = graphics }
            result.env.merge(overrides.env ?? [:]) { _, new in new }
            result.dllOverrides.merge(overrides.dllOverrides ?? [:]) { _, new in new }
            if let args = overrides.args { result.launch?.args = args }
        }
        return result
    }
}

public enum OverlayMatcher {
    public static func matches(_ condition: OverlayCondition, _ hardware: HardwareProfile) -> Bool {
        if let chip = condition.chip, !Glob.matches(chip, hardware.chip) { return false }
        if let families = condition.chipFamily,
           !families.values.contains(where: { $0.caseInsensitiveCompare(hardware.chipFamily) == .orderedSame }) {
            return false
        }
        if let tiers = condition.chipTier,
           !tiers.values.contains(where: { $0.caseInsensitiveCompare(hardware.chipTier) == .orderedSame }) {
            return false
        }
        if let memory = condition.memoryGB, !memory.matches(hardware.memoryGB) { return false }
        if let gpu = condition.gpuCores {
            guard let cores = hardware.gpuCores, gpu.matches(cores) else { return false }
        }
        if let macos = condition.macos, !macos.matches(hardware.macOSVersion) { return false }
        if let rosetta = condition.rosetta, rosetta != hardware.rosetta { return false }
        return true
    }
}

/// `*` matches any run of characters and `?` matches one. Case-insensitive.
enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        var regex = "^"
        for character in pattern {
            switch character {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
