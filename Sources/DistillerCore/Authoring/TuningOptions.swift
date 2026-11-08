import Foundation

/// A curated, documented setting a player can try in a recipe's "Performance & display"
/// section. Each one is an ordinary recipe environment variable underneath, so it's shared
/// with the recipe and stays within `RecipePolicy`'s allowed prefixes.
///
/// Only settings documented for the versions Distiller installs belong here (checked
/// 2026-11-07): DXVK-macOS 1.10.3 async, DXMT 0.80, and Apple's Metal HUD.
public struct TuningOption: Identifiable, Sendable {
    public struct Choice: Hashable, Sendable {
        public var label: String
        /// nil means the variable isn't set (the layer's own default).
        public var value: String?

        public init(_ label: String, _ value: String?) {
            self.label = label
            self.value = value
        }
    }

    public enum Control: Sendable {
        /// On sets the variable to `on`; off removes it.
        case toggle(on: String)
        case choice([Choice])
        /// One `key=value` entry inside `DXMT_CONFIG` ("k1=v1;k2=v2;").
        case dxmtConfig(key: String, choices: [Choice])
    }

    public var id: String
    public var title: String
    public var explanation: String
    public var tradeoff: String?
    public var envKey: String
    public var control: Control
    public var layers: Set<GraphicsBackend>
    public var documentation: URL
}

public enum TuningOptions {
    public static let all: [TuningOption] = [
        TuningOption(
            id: "dxvk-async",
            title: "Compile shaders in the background",
            explanation: "DXVK builds each new shader without pausing the game. Usually removes most stutter and can raise the frame rate a lot (Guild Wars 2 went from 15 to 60 fps).",
            tradeoff: "An object can be missing for a frame or two the first time its shader is needed.",
            envKey: "DXVK_ASYNC",
            control: .toggle(on: "1"),
            layers: [.dxvk],
            documentation: URL(string: "https://github.com/Gcenx/DXVK-macOS")!
        ),
        TuningOption(
            id: "dxvk-frame-rate",
            title: "Frame rate limit",
            explanation: "Caps how many frames DXVK renders each second. A limit at or below what the game reaches steadily feels smoother and keeps the Mac cooler and quieter.",
            tradeoff: nil,
            envKey: "DXVK_FRAME_RATE",
            control: .choice([.init("No limit", nil), .init("30 fps", "30"), .init("60 fps", "60"), .init("120 fps", "120")]),
            layers: [.dxvk],
            documentation: URL(string: "https://github.com/doitsujin/dxvk/tree/v1.10.3#frame-rate-limit")!
        ),
        TuningOption(
            id: "dxvk-hud",
            title: "On-screen stats",
            explanation: "DXVK draws a small overlay in the game window, useful while tuning settings.",
            tradeoff: nil,
            envKey: "DXVK_HUD",
            control: .choice([
                .init("Off", nil),
                .init("Frame rate", "fps"),
                .init("Frame rate and frame times", "fps,frametimes"),
                .init("Detailed (GPU, load, memory, shader compiles)", "devinfo,fps,frametimes,gpuload,memory,compiler"),
            ]),
            layers: [.dxvk],
            documentation: URL(string: "https://github.com/doitsujin/dxvk/tree/v1.10.3#hud")!
        ),
        TuningOption(
            id: "dxmt-metalfx",
            title: "MetalFX upscaling",
            explanation: "DXMT renders at a lower resolution and Apple's MetalFX scales the picture up to the window (by default to twice the rendered size). Raises the frame rate in demanding games.",
            tradeoff: "The picture can look slightly softer.",
            envKey: "DXMT_METALFX_SPATIAL_SWAPCHAIN",
            control: .toggle(on: "1"),
            layers: [.dxmt],
            documentation: URL(string: "https://github.com/3Shain/dxmt/blob/v0.80/docs/CUSTOMIZATION.md")!
        ),
        TuningOption(
            id: "dxmt-frame-pacing",
            title: "Frame pacing",
            explanation: "Lets Metal pace the game's frames at a steady rate. Choose a rate that divides your display's refresh rate (for example 30, 40, 60 or 120 on a 120 Hz display).",
            tradeoff: nil,
            envKey: "DXMT_CONFIG",
            control: .dxmtConfig(key: "d3d11.preferredMaxFrameRate", choices: [
                .init("Game decides", nil), .init("30 fps", "30"), .init("40 fps", "40"), .init("60 fps", "60"), .init("120 fps", "120"),
            ]),
            layers: [.dxmt],
            documentation: URL(string: "https://github.com/3Shain/dxmt/blob/v0.80/docs/CUSTOMIZATION.md")!
        ),
        TuningOption(
            id: "metal-hud",
            title: "Metal performance HUD",
            explanation: "Apple's overlay with frame rate, frame time and GPU memory, shown when the game draws with Metal. It also confirms the Metal path is in use.",
            tradeoff: nil,
            envKey: "MTL_HUD_ENABLED",
            control: .toggle(on: "1"),
            layers: [.d3dmetal, .dxmt, .dxvk],
            documentation: URL(string: "https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance")!
        ),
    ]

    public static func options(for backend: GraphicsBackend) -> [TuningOption] {
        all.filter { $0.layers.contains(backend) }
    }

    /// Settings the recipe builder turns on when a layer is chosen. Written into the recipe,
    /// where the player can see and change them.
    public static func builderDefaults(for backend: GraphicsBackend) -> [String: String] {
        backend == .dxvk ? ["DXVK_ASYNC": "1"] : [:]
    }

    /// The option's current value in `environment`; nil when it's at the layer's default.
    public static func value(of option: TuningOption, in environment: [String: String]) -> String? {
        switch option.control {
        case .toggle, .choice:
            return environment[option.envKey]
        case .dxmtConfig(let key, _):
            return dxmtConfigEntries(environment[option.envKey] ?? "").first { $0.key == key }?.value
        }
    }

    public static func isOn(_ option: TuningOption, in environment: [String: String]) -> Bool {
        guard case .toggle(let on) = option.control else { return false }
        return environment[option.envKey] == on
    }

    /// The environment after setting `option` to `value` (nil returns it to the default).
    public static func setting(_ option: TuningOption, to value: String?, in environment: [String: String]) -> [String: String] {
        var result = environment
        switch option.control {
        case .toggle, .choice:
            result[option.envKey] = value
        case .dxmtConfig(let key, _):
            var entries = dxmtConfigEntries(environment[option.envKey] ?? "").filter { $0.key != key }
            if let value { entries.append((key, value)) }
            result[option.envKey] = entries.isEmpty ? nil : entries.map { "\($0.key)=\($0.value);" }.joined()
        }
        return result
    }

    /// `DXMT_CONFIG` entries in order ("a=1;b=2;" → [(a, 1), (b, 2)]).
    static func dxmtConfigEntries(_ text: String) -> [(key: String, value: String)] {
        text.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Edits `KEY=value` text in place: replaces the key's line, appends it, or removes it
    /// (value nil), keeping every other line, comments included.
    public static func settingEnvironmentLine(_ key: String, to value: String?, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let index = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false }
            return trimmed.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } == key
        }
        switch (index, value) {
        case (let index?, let value?): lines[index] = "\(key)=\(value)"
        case (let index?, nil): lines.remove(at: index)
        case (nil, let value?):
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines.append("\(key)=\(value)")
        case (nil, nil): break
        }
        return lines.joined(separator: "\n")
    }
}
