import Foundation
import DistillerCore

/// ProtonDB-style playability, from best to worst.
public enum PlayabilityTier: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    case platinum, gold, silver, bronze, borked

    public var id: String { rawValue }

    public var score: Double {
        switch self {
        case .platinum: return 4
        case .gold: return 3
        case .silver: return 2
        case .bronze: return 1
        case .borked: return 0
        }
    }

    public init(score: Double) {
        let rounded = Int(score.rounded())
        self = PlayabilityTier.allCases.first { Int($0.score) == rounded } ?? .borked
    }

    public var displayName: String { rawValue.capitalized }

    public var explanation: String {
        switch self {
        case .platinum: return "Runs perfectly out of the box"
        case .gold: return "Runs perfectly with the tweaks in the recipe"
        case .silver: return "Playable, with minor issues"
        case .bronze: return "Runs, with major issues"
        case .borked: return "Doesn't run"
        }
    }

    public static func < (lhs: PlayabilityTier, rhs: PlayabilityTier) -> Bool { lhs.score < rhs.score }
}

/// The shape of `index.json`, as written by `scripts/build_index.py` in distiller-recipes.
/// Schema 2 added each game's details (from `games/<slug>.yaml`), a summary across its
/// recipes, and `detail` (the path of `games/<slug>.json`). Schema 1 files still decode.
public struct CommunityIndex: Codable, Equatable, Sendable {
    public var schema: Int
    public var generatedAt: String
    public var repository: String
    public var games: [IndexGame]

    enum CodingKeys: String, CodingKey {
        case schema, repository, games
        case generatedAt = "generated_at"
    }
}

public struct IndexGame: Codable, Equatable, Sendable, Identifiable {
    public var slug: String
    public var title: String
    public var recipes: [IndexRecipe]
    public var publisher: String?
    public var developer: String?
    public var releaseYear: Int?
    public var genres: [String]?
    public var description: String?
    public var website: String?
    public var stores: [IndexStore]?
    public var installer: PublicInstaller?
    /// Path of the game's detail file, relative to the index: "games/<slug>.json".
    public var detail: String?
    /// Across all its recipes.
    public var summary: ReportSummary?
    /// Graphics layers its recipes use.
    public var graphics: [String]?
    /// Date of the newest report ("2026-11-01").
    public var updated: String?
    /// The game's icon, relative to the index: "media/<slug>/icon.png". See `CommunityRepository.mediaURL`.
    public var icon: String?
    public var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, title, recipes, publisher, developer, genres, description, website, stores, installer, detail, summary, graphics, updated, icon
        case releaseYear = "release_year"
    }
}

public struct IndexStore: Codable, Equatable, Sendable, Hashable {
    /// "publisher", "steam", "gog", "epic", "microsoft" or "other".
    public var name: String
    public var url: String
}

public struct IndexRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    /// Repository-relative path, such as "recipes/example-dx11-game/d3dmetal.yaml".
    public var path: String
    public var graphics: String
    public var runnerFamily: String
    public var forkedFrom: String?
    public var summary: ReportSummary
    public var byHardware: [String: ReportSummary]
    /// Up to three screenshots from the recipe's community check, cover first, relative to
    /// the index: "media/<slug>/<recipe-id>/1.jpg".
    public var screenshots: [String]?
    public var cover: String? { screenshots?.first }

    enum CodingKeys: String, CodingKey {
        case id, name, path, graphics, summary, screenshots
        case runnerFamily = "runner_family"
        case forkedFrom = "forked_from"
        case byHardware = "by_hardware"
    }
}

public struct ReportSummary: Codable, Equatable, Sendable {
    public var reports: Int
    /// Mean tier score from 0 (borked) to 4 (platinum). Absent when there are no reports.
    public var score: Double?
    public var tier: PlayabilityTier?
    public var medianFPS: Double?

    enum CodingKeys: String, CodingKey {
        case reports, score, tier
        case medianFPS = "median_fps"
    }
}

public struct RankedRecipe: Identifiable, Sendable {
    public var recipe: IndexRecipe
    /// Weighted score from 0 to 4, or nil without any reports.
    public var score: Double?
    /// Plain-language basis for the score, such as "3 reports from Macs like yours".
    public var evidence: String
    public var id: String { recipe.id }
    public var tier: PlayabilityTier? { score.map(PlayabilityTier.init(score:)) }
}

/// Ranks a game's recipes for one Mac. Reports from the exact hardware key count fully,
/// reports from the same chip family count half, and all others a quarter.
public enum RecipeRanker {
    public static func rank(_ recipes: [IndexRecipe], for hardware: HardwareProfile) -> [RankedRecipe] {
        recipes.map { recipe in
            var weightedScore = 0.0
            var totalWeight = 0.0
            var exact = 0
            var sameFamily = 0
            for (key, summary) in recipe.byHardware {
                guard let score = summary.score, summary.reports > 0 else { continue }
                let weight: Double
                if key == hardware.hardwareKey {
                    weight = 1
                    exact += summary.reports
                } else if key.split(separator: "-").first.map(String.init) == hardware.chipFamily {
                    weight = 0.5
                    sameFamily += summary.reports
                } else {
                    weight = 0.25
                }
                weightedScore += score * weight * Double(summary.reports)
                totalWeight += weight * Double(summary.reports)
            }
            let evidence: String
            if exact > 0 {
                evidence = "\(exact) \(exact == 1 ? "report" : "reports") from Macs like yours"
            } else if sameFamily > 0 {
                evidence = "\(sameFamily) \(sameFamily == 1 ? "report" : "reports") from other \(hardware.chipFamily) Macs"
            } else if recipe.summary.reports > 0 {
                evidence = "\(recipe.summary.reports) \(recipe.summary.reports == 1 ? "report" : "reports") from other Macs"
            } else {
                evidence = "No reports yet"
            }
            return RankedRecipe(recipe: recipe, score: totalWeight > 0 ? weightedScore / totalWeight : nil, evidence: evidence)
        }
        .sorted { ($0.score ?? -1) > ($1.score ?? -1) }
    }
}
