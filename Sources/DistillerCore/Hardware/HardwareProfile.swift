import Foundation

/// What a recipe overlay or a compatibility report knows about a Mac.
/// Contains nothing that identifies a person or a specific machine.
public struct HardwareProfile: Codable, Equatable, Sendable {
    /// The full chip name, such as "Apple M3 Pro".
    public var chip: String
    /// "M1", "M2", … or "Intel".
    public var chipFamily: String
    /// "Base", "Pro", "Max" or "Ultra".
    public var chipTier: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var gpuCores: Int?
    public var memoryGB: Int
    /// The macOS version, such as "27.1".
    public var macOS: String
    public var rosetta: Bool

    enum CodingKeys: String, CodingKey {
        case chip, rosetta
        case chipFamily = "chip_family"
        case chipTier = "chip_tier"
        case performanceCores = "cpu_cores_performance"
        case efficiencyCores = "cpu_cores_efficiency"
        case gpuCores = "gpu_cores"
        case memoryGB = "memory_gb"
        case macOS = "macos"
    }

    public init(
        chip: String,
        chipFamily: String,
        chipTier: String,
        performanceCores: Int,
        efficiencyCores: Int,
        gpuCores: Int?,
        memoryGB: Int,
        macOS: String,
        rosetta: Bool
    ) {
        self.chip = chip
        self.chipFamily = chipFamily
        self.chipTier = chipTier
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.macOS = macOS
        self.rosetta = rosetta
    }

    public var macOSVersion: VersionNumber { VersionNumber(macOS) }
    public var macOSMajor: Int { macOSVersion.parts.first ?? 0 }

    /// The key reports are grouped by, such as "M3-Pro-18gpu-18gb-macos27".
    /// `scripts/build_index.py` in the recipe repository computes the same key.
    public var hardwareKey: String {
        let gpu = gpuCores.map(String.init) ?? "x"
        return "\(chipFamily)-\(chipTier)-\(gpu)gpu-\(memoryGB)gb-macos\(macOSMajor)"
    }

    /// One-line summary for the UI.
    public var summary: String {
        "\(chip) · \(memoryGB) GB · macOS \(macOS)"
    }

    /// Splits "Apple M3 Pro" into ("M3", "Pro"), and "Apple M2" into ("M2", "Base").
    public static func parseChip(_ brand: String) -> (family: String, tier: String) {
        let words = brand.split(separator: " ").map(String.init)
        let familyIndex = words.firstIndex { word in
            word.count >= 2 && word.first == "M" && word.dropFirst().allSatisfy(\.isNumber)
        }
        guard let familyIndex else {
            return (brand.localizedCaseInsensitiveContains("intel") ? "Intel" : "Unknown", "Base")
        }
        let next = familyIndex + 1 < words.count ? words[familyIndex + 1] : ""
        let tier = ["Pro", "Max", "Ultra"].contains(next) ? next : "Base"
        return (words[familyIndex], tier)
    }
}
