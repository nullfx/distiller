import Foundation

public enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case wine, graphics, winetricks

    public var displayName: String {
        switch self {
        case .wine: return "Wine builds"
        case .graphics: return "Graphics layers"
        case .winetricks: return "Winetricks"
        }
    }
}

/// Where a graphics layer's files go.
public enum GraphicsPlacement: String, Codable, CaseIterable, Sendable {
    /// The component's `lib/` folder is merged over the Wine build's `lib/` (D3DMetal, DXMT).
    case wineLib = "wine_lib"
    /// The component's `system32/` and `syswow64/` DLLs are copied into the prefix (DXVK).
    case prefixDLLs = "prefix_dlls"
}

/// The `component.json` stored at the root of every installed component.
public struct ComponentManifest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: ComponentKind
    public var version: String
    public var displayName: String
    public var arch: CPUArch
    /// Wine builds: "crossover", "winehq" or "gptk".
    public var family: String?
    /// Graphics layers: the backend this provides.
    public var provides: GraphicsBackend?
    public var placement: GraphicsPlacement?
    /// Path of the main executable, relative to the component root.
    public var executable: String?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    public var license: String?
    public var source: String?
    public var sha256: String?
    /// Set on composed builds: the components they were made from.
    public var composedFrom: [String]?
    /// `wine_lib` layers: DLLs that must also be in each bottle's `system32` (64-bit, from
    /// `lib/wine/x86_64-windows`) and `syswow64` (32-bit, from `lib/wine/i386-windows`),
    /// because Wine won't find them as builtins otherwise. DXMT's `winemetal.dll` is one.
    public var alsoInPrefix: [String]?

    enum CodingKeys: String, CodingKey {
        case id, kind, version, arch, family, provides, placement, executable, env, license, source, sha256
        case displayName = "display_name"
        case dllOverrides = "dll_overrides"
        case composedFrom = "composed_from"
        case alsoInPrefix = "also_in_prefix"
    }

    /// `alsoInPrefix`, with the known default for DXMT components installed before the field existed.
    public var dllsAlsoInPrefix: [String] {
        alsoInPrefix ?? (provides == .dxmt && placement == .wineLib ? ["winemetal.dll"] : [])
    }

    public init(
        id: String,
        kind: ComponentKind,
        version: String,
        displayName: String,
        arch: CPUArch,
        family: String? = nil,
        provides: GraphicsBackend? = nil,
        placement: GraphicsPlacement? = nil,
        executable: String? = nil,
        env: [String: String]? = nil,
        dllOverrides: [String: String]? = nil,
        license: String? = nil,
        source: String? = nil,
        sha256: String? = nil,
        composedFrom: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.version = version
        self.displayName = displayName
        self.arch = arch
        self.family = family
        self.provides = provides
        self.placement = placement
        self.executable = executable
        self.env = env
        self.dllOverrides = dllOverrides
        self.license = license
        self.source = source
        self.sha256 = sha256
        self.composedFrom = composedFrom
    }
}

public struct InstalledComponent: Equatable, Sendable, Identifiable, Hashable {
    public var manifest: ComponentManifest
    public var directory: URL

    public init(manifest: ComponentManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    /// "id@version", unique across installed components.
    public var id: String { "\(manifest.id)@\(manifest.version)" }

    public var requiresRosetta: Bool { manifest.arch == .x86_64 }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The `wine` loader. Wine 11 uses a single `wine` binary; older builds may only have `wine64`.
    public var wineBinary: URL? {
        guard manifest.kind == .wine else { return nil }
        if let executable = manifest.executable {
            return directory.appendingPathComponent(executable)
        }
        for candidate in ["bin/wine", "bin/wine64"] {
            let url = directory.appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public var wineserverBinary: URL? {
        wineBinary?.deletingLastPathComponent().appendingPathComponent("wineserver")
    }

    /// The winetricks script, for winetricks components.
    public var scriptURL: URL? {
        guard manifest.kind == .winetricks else { return nil }
        return directory.appendingPathComponent(manifest.executable ?? "winetricks")
    }
}
