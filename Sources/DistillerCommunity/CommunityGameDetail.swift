import Foundation
import DistillerCore

/// The shape of `games/<slug>.json`, as written by `scripts/build_index.py` in
/// distiller-recipes: each recipe's content and the reports behind its rating. The index
/// (`IndexGame`) already has the game's details; this adds what a game's page shows below them.
public struct CommunityGameDetail: Decodable, Sendable {
    public var slug: String
    public var title: String
    public var recipes: [DetailRecipe]

    public func recipe(_ id: String) -> DetailRecipe? { recipes.first { $0.id == id } }
}

/// One recipe in a game's detail file.
public struct DetailRecipe: Decodable, Sendable, Identifiable {
    public var id: String
    public var path: String
    /// The recipe itself, when it decodes; a page still shows the rest if it doesn't.
    public var recipe: Recipe?
    /// Newest first, as the index script writes them.
    public var reports: [CommunityReport]

    enum CodingKeys: String, CodingKey { case id, path, recipe, reports }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        recipe = try? container.decodeIfPresent(Recipe.self, forKey: .recipe)
        reports = (try? container.decodeIfPresent([Lenient<CommunityReport>].self, forKey: .reports))?.compactMap(\.value) ?? []
    }
}

/// A compatibility report, as published in a game's detail file.
public struct CommunityReport: Decodable, Sendable, Identifiable {
    public var date: String?
    public var tier: PlayabilityTier?
    public var hardwareKey: String?
    public var fpsAverage: Double?
    public var notes: String?

    public var id: String { [date, hardwareKey, tier?.rawValue, notes].compactMap { $0 }.joined(separator: "|") }

    enum CodingKeys: String, CodingKey {
        case date, tier, notes
        case hardwareKey = "hardware_key"
        case fpsAverage = "fps_avg"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try? container.decodeIfPresent(String.self, forKey: .date)
        tier = (try? container.decodeIfPresent(String.self, forKey: .tier)).flatMap { $0.flatMap(PlayabilityTier.init(rawValue:)) }
        hardwareKey = try? container.decodeIfPresent(String.self, forKey: .hardwareKey)
        fpsAverage = try? container.decodeIfPresent(Double.self, forKey: .fpsAverage)
        notes = try? container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// Decodes an element if it can, so one odd entry doesn't hide the rest.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: - Describing catalogue data

/// Human-readable descriptions of catalogue values, matching the website
/// (`site/assets/catalogue-data.js`).
public enum CatalogueText {
    /// "M3-Pro-18gpu-36gb-macos27" → "M3 Pro · 18-core GPU · 36 GB · macOS 27".
    public static func hardware(_ key: String) -> String {
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count == 5,
              parts[0].first == "M", Int(parts[0].dropFirst()) != nil,
              parts[1].allSatisfy(\.isLetter), !parts[1].isEmpty,
              let gpu = Int(parts[2].replacingOccurrences(of: "gpu", with: "")), parts[2].hasSuffix("gpu"),
              let memory = Int(parts[3].replacingOccurrences(of: "gb", with: "")), parts[3].hasSuffix("gb"),
              let macOS = Int(parts[4].replacingOccurrences(of: "macos", with: "")), parts[4].hasPrefix("macos")
        else { return key }
        let chip = parts[1] == "Base" ? parts[0] : "\(parts[0]) \(parts[1])"
        return "\(chip) · \(gpu)-core GPU · \(memory) GB · macOS \(macOS)"
    }

    public static func graphics(_ id: String) -> String {
        GraphicsBackend(rawValue: id)?.displayName ?? id
    }

    public static func wineFamily(_ family: String) -> String {
        ["winehq": "WineHQ", "gptk": "Game Porting Toolkit", "any": "Any Wine"][family] ?? family
    }

    public static func store(_ name: String) -> String {
        ["publisher": "Publisher's site", "steam": "Steam", "gog": "GOG", "epic": "Epic Games Store", "microsoft": "Microsoft Store"][name] ?? "Store"
    }

    /// A recipe's settings as label and value pairs, in the order the website shows them.
    public static func settings(of recipe: Recipe) -> [(label: String, value: String)] {
        var lines: [(String, String)] = []
        let runner = recipe.stack.runner
        lines.append(("Wine", wineFamily(runner.family) + (runner.minVersion.map { " \($0) or later" } ?? "")))
        lines.append(("Graphics", recipe.stack.graphics.displayName))
        if let sync = recipe.stack.sync { lines.append(("Sync", sync.rawValue)) }
        if let windows = recipe.prefix?.windows {
            lines.append(("Windows version", windows.hasPrefix("win") ? "Windows " + windows.dropFirst(3) : windows))
        }
        if let verbs = recipe.prefix?.winetricks, !verbs.isEmpty { lines.append(("Winetricks", verbs.joined(separator: ", "))) }
        if let overrides = recipe.prefix?.dllOverrides, !overrides.isEmpty {
            lines.append(("DLL overrides", overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
        }
        if let env = recipe.env, !env.isEmpty {
            lines.append(("Environment", env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
        }
        if let launch = recipe.launch {
            lines.append(("Launches", launch.exe))
            if let args = launch.args, !args.isEmpty { lines.append(("Arguments", args.joined(separator: " "))) }
        }
        if let overlays = recipe.overlays, !overlays.isEmpty {
            lines.append(("Hardware overlays", "\(overlays.count) (settings that apply on particular Macs)"))
        }
        return lines
    }

    /// Only `https:` links from the catalogue are followed.
    public static func safeLink(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
