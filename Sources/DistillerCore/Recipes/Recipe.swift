import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case d3dmetal, dxmt, dxvk, wined3d

    public var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK + MoltenVK"
        case .wined3d: return "WineD3D"
        }
    }
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case msync, esync, none
}

public enum CPUArch: String, Codable, CaseIterable, Sendable {
    case x86_64, arm64, universal
}

/// A shareable, declarative description of how to install and run one game.
/// The JSON Schema in the distiller-recipes repository is the reference for this format.
public struct Recipe: Codable, Equatable, Sendable {
    /// The newest recipe schema this version of Distiller reads.
    public static let supportedSchema = 2
    /// The schema new recipes start at: 1, unless they use something newer (`requiredSchema`),
    /// so older versions of Distiller can still read them.
    public static let baseSchema = 1

    public var schema: Int
    public var id: String
    public var name: String?
    /// "<game-slug>/<recipe-id>" of the recipe this one was forked from.
    public var forkedFrom: String?
    public var authors: [String]?
    public var notes: String?
    public var game: GameInfo
    public var stack: StackSpec
    public var prefix: PrefixSpec?
    public var install: [InstallStep]?
    public var env: [String: String]?
    public var launch: LaunchSpec?
    public var overlays: [Overlay]?

    enum CodingKeys: String, CodingKey {
        case schema, id, name, authors, notes, game, stack, prefix, install, env, launch, overlays
        case forkedFrom = "forked_from"
    }

    public init(
        schema: Int = Recipe.baseSchema,
        id: String,
        name: String? = nil,
        forkedFrom: String? = nil,
        authors: [String]? = nil,
        notes: String? = nil,
        game: GameInfo,
        stack: StackSpec,
        prefix: PrefixSpec? = nil,
        install: [InstallStep]? = nil,
        env: [String: String]? = nil,
        launch: LaunchSpec? = nil,
        overlays: [Overlay]? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.forkedFrom = forkedFrom
        self.authors = authors
        self.notes = notes
        self.game = game
        self.stack = stack
        self.prefix = prefix
        self.install = install
        self.env = env
        self.launch = launch
        self.overlays = overlays
    }
}

public struct GameInfo: Codable, Equatable, Sendable {
    public var title: String
    public var slug: String
    public var publisher: String?
    public var website: String?
    /// The publisher's official, publicly downloadable installer. Needed to share a recipe:
    /// community recipes install from it, and Distiller proves that works first (`CommunityCheck`).
    public var installer: PublicInstaller?

    public init(title: String, slug: String, publisher: String? = nil, website: String? = nil, installer: PublicInstaller? = nil) {
        self.title = title
        self.slug = slug
        self.publisher = publisher
        self.website = website
        self.installer = installer
    }
}

/// Where anyone can download a game's installer from its publisher. Only the official URL
/// belongs here, never a mirror or re-hosted copy.
public struct PublicInstaller: Codable, Equatable, Sendable {
    /// HTTPS URL of the installer (.exe or .msi) on the publisher's own servers.
    public var url: String
    /// The publisher's download page (HTTPS), where a player can always get the installer.
    /// Optional; Distiller records it when the installer is downloaded from the page.
    public var page: String?
    /// The installer changes with every update (a game launcher's, for example), so it's
    /// verified by its publisher's signature rather than a fixed checksum. Schema 2.
    public var updates: Bool?
    /// Arguments for the installer, such as a silent-install switch.
    public var args: [String]?

    public init(url: String, page: String? = nil, updates: Bool? = nil, args: [String]? = nil) {
        self.url = url
        self.page = page
        self.updates = updates
        self.args = args
    }
}

public struct RunnerRequirement: Codable, Equatable, Sendable {
    /// "crossover", "winehq", "gptk", or "any".
    public var family: String
    public var minVersion: String?
    public var arch: CPUArch?

    enum CodingKeys: String, CodingKey {
        case family, arch
        case minVersion = "min_version"
    }

    public init(family: String, minVersion: String? = nil, arch: CPUArch? = nil) {
        self.family = family
        self.minVersion = minVersion
        self.arch = arch
    }
}

public struct StackSpec: Codable, Equatable, Sendable {
    public var runner: RunnerRequirement
    public var graphics: GraphicsBackend
    public var sync: SyncMode?

    public init(runner: RunnerRequirement, graphics: GraphicsBackend, sync: SyncMode? = nil) {
        self.runner = runner
        self.graphics = graphics
        self.sync = sync
    }
}

public struct PrefixSpec: Codable, Equatable, Sendable {
    /// A winecfg version name such as "win10", "win11" or "win7".
    public var windows: String?
    public var retina: Bool?
    public var winetricks: [String]?
    public var dllOverrides: [String: String]?
    public var registry: [RegistryEdit]?

    enum CodingKeys: String, CodingKey {
        case windows, retina, winetricks, registry
        case dllOverrides = "dll_overrides"
    }

    public init(
        windows: String? = nil,
        retina: Bool? = nil,
        winetricks: [String]? = nil,
        dllOverrides: [String: String]? = nil,
        registry: [RegistryEdit]? = nil
    ) {
        self.windows = windows
        self.retina = retina
        self.winetricks = winetricks
        self.dllOverrides = dllOverrides
        self.registry = registry
    }
}

public struct RegistryEdit: Codable, Equatable, Sendable {
    /// For example `HKCU\Software\Wine\Mac Driver`.
    public var key: String
    public var values: [String: RegistryValue]

    public init(key: String, values: [String: RegistryValue]) {
        self.key = key
        self.values = values
    }
}

/// A registry value: a plain string, or `{ dword: 1 }` for a DWORD.
/// The explicit DWORD form avoids guessing whether "1" was meant as text or a number.
public enum RegistryValue: Codable, Equatable, Sendable {
    case string(String)
    case dword(UInt32)

    private enum Keys: String, CodingKey { case dword }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Keys.self), keyed.contains(.dword) {
            self = .dword(try keyed.decode(UInt32.self, forKey: .dword))
        } else {
            self = .string(try decoder.singleValueContainer().decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .dword(let value):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(value, forKey: .dword)
        }
    }
}

public struct LaunchSpec: Codable, Equatable, Sendable {
    /// A Windows path such as `C:\Games\Example\Game.exe`.
    public var exe: String
    public var args: [String]?
    public var workingDir: String?

    enum CodingKeys: String, CodingKey {
        case exe, args
        case workingDir = "working_dir"
    }

    public init(exe: String, args: [String]? = nil, workingDir: String? = nil) {
        self.exe = exe
        self.args = args
        self.workingDir = workingDir
    }
}

/// A patch applied only when `when` matches the Mac's hardware fingerprint.
public struct Overlay: Codable, Equatable, Sendable {
    public var when: OverlayCondition
    public var note: String?
    public var stack: StackPatch?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    /// Appended to the recipe's registry edits.
    public var registry: [RegistryEdit]?
    /// Replaces the recipe's winetricks list.
    public var winetricks: [String]?
    /// Added to the end of the winetricks list.
    public var appendWinetricks: [String]?
    /// Replaces the launch arguments.
    public var args: [String]?

    enum CodingKeys: String, CodingKey {
        case when, note, stack, env, registry, winetricks, args
        case dllOverrides = "dll_overrides"
        case appendWinetricks = "append_winetricks"
    }

    public init(
        when: OverlayCondition,
        note: String? = nil,
        stack: StackPatch? = nil,
        env: [String: String]? = nil,
        dllOverrides: [String: String]? = nil,
        registry: [RegistryEdit]? = nil,
        winetricks: [String]? = nil,
        appendWinetricks: [String]? = nil,
        args: [String]? = nil
    ) {
        self.when = when
        self.note = note
        self.stack = stack
        self.env = env
        self.dllOverrides = dllOverrides
        self.registry = registry
        self.winetricks = winetricks
        self.appendWinetricks = appendWinetricks
        self.args = args
    }
}

public struct StackPatch: Codable, Equatable, Sendable {
    public var runner: RunnerRequirement?
    public var graphics: GraphicsBackend?
    public var sync: SyncMode?

    public init(runner: RunnerRequirement? = nil, graphics: GraphicsBackend? = nil, sync: SyncMode? = nil) {
        self.runner = runner
        self.graphics = graphics
        self.sync = sync
    }
}

/// Every field that is present must match.
public struct OverlayCondition: Codable, Equatable, Sendable {
    /// A glob against the chip name, such as "Apple M1*".
    public var chip: String?
    public var chipFamily: StringList?
    public var chipTier: StringList?
    public var memoryGB: Comparison?
    public var gpuCores: Comparison?
    public var macos: Comparison?
    public var rosetta: Bool?

    enum CodingKeys: String, CodingKey {
        case chip, macos, rosetta
        case chipFamily = "chip_family"
        case chipTier = "chip_tier"
        case memoryGB = "memory_gb"
        case gpuCores = "gpu_cores"
    }

    public init(
        chip: String? = nil,
        chipFamily: StringList? = nil,
        chipTier: StringList? = nil,
        memoryGB: Comparison? = nil,
        gpuCores: Comparison? = nil,
        macos: Comparison? = nil,
        rosetta: Bool? = nil
    ) {
        self.chip = chip
        self.chipFamily = chipFamily
        self.chipTier = chipTier
        self.memoryGB = memoryGB
        self.gpuCores = gpuCores
        self.macos = macos
        self.rosetta = rosetta
    }
}

/// Decodes either `M1` or `[M1, M2]`.
public struct StringList: Codable, Equatable, Sendable, ExpressibleByArrayLiteral {
    public var values: [String]

    public init(_ values: [String]) { self.values = values }
    public init(arrayLiteral elements: String...) { self.values = elements }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            values = list
        } else {
            values = [try container.decode(String.self)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1 {
            try container.encode(values[0])
        } else {
            try container.encode(values)
        }
    }
}

extension Recipe {
    /// The oldest schema that can describe this recipe: 2 if anything is verified by a
    /// publisher's signature (a `signer` download, or an installer that `updates`), else 1.
    public var requiredSchema: Int {
        let signed = (install ?? []).contains { step in
            if case .download(let download) = step { return download.signer != nil }
            return false
        }
        return signed || game.installer?.updates == true ? 2 : 1
    }
}
