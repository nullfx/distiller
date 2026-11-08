import Foundation

/// The graphics APIs a game was found to use, oldest to newest.
public enum GraphicsAPI: String, Codable, CaseIterable, Sendable, Comparable {
    case directDraw, direct3D8, direct3D9, direct3D10, direct3D11, direct3D12, openGL, vulkan

    public var displayName: String {
        switch self {
        case .directDraw: return "DirectDraw"
        case .direct3D8: return "Direct3D 8"
        case .direct3D9: return "Direct3D 9"
        case .direct3D10: return "Direct3D 10"
        case .direct3D11: return "Direct3D 11"
        case .direct3D12: return "Direct3D 12"
        case .openGL: return "OpenGL"
        case .vulkan: return "Vulkan"
        }
    }

    public static func < (lhs: GraphicsAPI, rhs: GraphicsAPI) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A Windows program found in a game folder or bottle, as a candidate to launch.
public struct DiscoveredProgram: Identifiable, Equatable, Sendable {
    /// Path relative to the folder that was searched, with forward slashes.
    public var relativePath: String
    public var url: URL
    public var size: Int64
    /// Higher is more likely to be the game itself.
    public var score: Int

    public var id: String { relativePath }
    public var name: String { url.lastPathComponent }
}

/// What Distiller could tell about a game before installing it, and what it suggests.
public struct GameInspection: Equatable, Sendable {
    public var executable: URL?
    public var machine: PEFile.Machine?
    public var apis: [GraphicsAPI]
    public var isDotNet: Bool
    /// "Unity", "Unreal Engine", or nil.
    public var engine: String?
    public var suggestedGraphics: GraphicsBackend
    public var suggestedWinetricks: [String]
    public var suggestedWindowsVersion: String
    /// Plain-language reasons for each suggestion, for the UI.
    public var findings: [String]

    public init(
        executable: URL? = nil, machine: PEFile.Machine? = nil, apis: [GraphicsAPI] = [], isDotNet: Bool = false,
        engine: String? = nil, suggestedGraphics: GraphicsBackend = .d3dmetal, suggestedWinetricks: [String] = [],
        suggestedWindowsVersion: String = RecipeResolver.defaultWindowsVersion, findings: [String] = []
    ) {
        self.executable = executable
        self.machine = machine
        self.apis = apis
        self.isDotNet = isDotNet
        self.engine = engine
        self.suggestedGraphics = suggestedGraphics
        self.suggestedWinetricks = suggestedWinetricks
        self.suggestedWindowsVersion = suggestedWindowsVersion
        self.findings = findings
    }
}

/// Looks at a game's files to suggest recipe settings. Suggestions only: the player decides.
public enum GameInspector {
    /// DLL imports that point at a winetricks verb worth installing.
    static let runtimeHints: [(prefix: String, verb: String)] = [
        ("msvcp140", "vcrun2022"), ("vcruntime140", "vcrun2022"),
        ("msvcp120", "vcrun2013"), ("msvcr120", "vcrun2013"),
        ("msvcp110", "vcrun2012"), ("msvcr110", "vcrun2012"),
        ("msvcp100", "vcrun2010"), ("msvcr100", "vcrun2010"),
        ("msvcp90", "vcrun2008"), ("msvcr90", "vcrun2008"),
        ("msvcp80", "vcrun2005"), ("msvcr80", "vcrun2005"),
        ("d3dx9_", "d3dx9"), ("d3dx10_", "d3dx10"), ("d3dx11_43", "d3dx11_43"), ("d3dx11_42", "d3dx11_42"),
        ("d3dcompiler_47", "d3dcompiler_47"), ("d3dcompiler_46", "d3dcompiler_46"), ("d3dcompiler_43", "d3dcompiler_43"),
        ("xaudio2_7", "xact"), ("x3daudio1_7", "xact"), ("xactengine", "xact"),
        ("physxloader", "physx"), ("physx3", "physx"), ("openal32", "openal"),
        ("mfc42", "mfc42"), ("mfc140", "mfc140"),
    ]

    /// Inspects `executable`, and the DLLs beside it, which matters for engines such as
    /// Unity where the .exe is a small stub and `UnityPlayer.dll` does the rendering.
    /// `installed` lists the graphics layers present, so the suggestion is one that will run.
    public static func inspect(executable: URL, installedGraphics: Set<GraphicsBackend> = Set(GraphicsBackend.allCases)) -> GameInspection {
        var result = GameInspection(executable: executable)
        let main = PEFile.read(executable)
        result.machine = main?.machine
        result.isDotNet = main?.isDotNet ?? false

        var imports = main?.imports ?? []
        let folder = executable.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let siblingNames = Set(siblings.map { $0.lastPathComponent.lowercased() })
        for dll in siblings.filter({ $0.pathExtension.lowercased() == "dll" }).prefix(60) {
            imports.formUnion(PEFile.read(dll)?.imports ?? [])
        }
        // A DLL shipped beside the game counts too, such as d3dx9_43.dll in the game folder.
        imports.formUnion(siblingNames.filter { $0.hasSuffix(".dll") })

        if siblingNames.contains("unityplayer.dll") || siblingNames.contains("unitycrashhandler64.exe") {
            result.engine = "Unity"
        } else if executable.lastPathComponent.lowercased().hasSuffix("-shipping.exe")
                    || executable.path.lowercased().contains("/binaries/win64/") {
            result.engine = "Unreal Engine"
        }

        var apis: Set<GraphicsAPI> = []
        for name in imports {
            switch name {
            case "ddraw.dll": apis.insert(.directDraw)
            case "d3d8.dll": apis.insert(.direct3D8)
            case "d3d9.dll": apis.insert(.direct3D9)
            case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": apis.insert(.direct3D10)
            case "d3d11.dll": apis.insert(.direct3D11)
            case "d3d12.dll", "d3d12core.dll": apis.insert(.direct3D12)
            case "opengl32.dll": apis.insert(.openGL)
            case "vulkan-1.dll": apis.insert(.vulkan)
            default: break
            }
        }
        // Unity and Unreal choose their renderer at run time; DXGI alone means 10 or newer.
        if apis.isEmpty, imports.contains("dxgi.dll") { apis.insert(.direct3D11) }
        result.apis = apis.sorted()

        var verbs: [String] = []
        for name in imports.sorted() {
            for hint in runtimeHints where name.hasPrefix(hint.prefix) && !verbs.contains(hint.verb) {
                verbs.append(hint.verb)
            }
        }
        result.suggestedWinetricks = verbs.filter { RecipePolicy.winetricksVerbs.contains($0) }

        let newest = result.apis.filter { ![.openGL, .vulkan].contains($0) }.max()
        var findings: [String] = []
        if let machine = main?.machine {
            switch machine {
            case .x86: findings.append("\(executable.lastPathComponent) is a 32-bit Windows program.")
            case .x64: findings.append("\(executable.lastPathComponent) is a 64-bit Windows program.")
            case .arm64: findings.append("\(executable.lastPathComponent) is built for ARM Windows, which Wine on macOS can't run yet.")
            case .other: break
            }
        } else {
            findings.append("\(executable.lastPathComponent) couldn't be read as a Windows program.")
        }
        if let engine = result.engine { findings.append("It looks like a \(engine) game.") }
        if !result.apis.isEmpty {
            findings.append("It uses \(result.apis.map(\.displayName).joined(separator: ", ")).")
        }
        if result.isDotNet {
            findings.append("It's a .NET program. Wine's built-in Mono runs many of these; add dotnet48 only if it doesn't start.")
        }

        func available(_ backend: GraphicsBackend) -> Bool { installedGraphics.contains(backend) || backend == .wined3d }
        switch newest {
        case .direct3D12?, .direct3D11?, .direct3D10?:
            if available(.d3dmetal) {
                result.suggestedGraphics = .d3dmetal
                findings.append("D3DMetal is suggested: it translates Direct3D 10–12 to Metal.")
            } else if newest != .direct3D12, available(.dxmt) {
                result.suggestedGraphics = .dxmt
                findings.append("DXMT is suggested because D3DMetal isn't available (not imported, or this Wine build can't run it).")
            } else if available(.dxvk) {
                result.suggestedGraphics = .dxvk
                findings.append("DXVK is suggested because D3DMetal isn't available (not imported, or this Wine build can't run it).")
            } else {
                result.suggestedGraphics = .wined3d
                findings.append("WineD3D is selected because no faster graphics layer is installed. Import D3DMetal from the Game Porting Toolkit for better results.")
            }
        case .direct3D9?, .direct3D8?, .directDraw?:
            result.suggestedGraphics = .wined3d
            findings.append("WineD3D is suggested: D3DMetal doesn't handle Direct3D 9 and older.")
        default:
            // Unknown API (often loaded at run time, as Guild Wars 2 does): the fastest usable layer.
            result.suggestedGraphics = [GraphicsBackend.d3dmetal, .dxmt, .dxvk].first(where: available) ?? .wined3d
            if result.apis.contains(.openGL) || result.apis.contains(.vulkan) {
                result.suggestedGraphics = .wined3d
                findings.append("OpenGL and Vulkan games don't use a Direct3D layer, so WineD3D is fine.")
            } else if result.apis.isEmpty {
                findings.append("No graphics API was found in the program's imports, so the default is selected. Try another if it doesn't start.")
            }
        }
        let isVeryOld = result.apis.contains { $0 == .direct3D8 || $0 == .directDraw }
        if isVeryOld, let newest, newest <= .direct3D9 {
            result.suggestedWindowsVersion = "win7"
        }
        result.findings = findings
        return result
    }

    /// Winetricks verbs suggested by redistributable folders a game ships with,
    /// such as `_CommonRedist/vcredist/2019` or `DirectX/Jun2010`.
    public static func redistributableHints(in folder: URL) -> [String] {
        var verbs: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants(); continue }
            let path = url.path.lowercased()
            guard path.contains("redist") || path.contains("directx") || path.contains("dotnet") else { continue }
            let name = url.lastPathComponent.lowercased()
            for (needle, verb) in [("2022", "vcrun2022"), ("2019", "vcrun2022"), ("2017", "vcrun2022"), ("2015", "vcrun2022"),
                                   ("2013", "vcrun2013"), ("2012", "vcrun2012"), ("2010", "vcrun2010"), ("2008", "vcrun2008"), ("2005", "vcrun2005")]
            where path.contains("vc") && name.contains(needle) && !verbs.contains(verb) {
                verbs.append(verb)
            }
            if (name.contains("dxsetup") || name.contains("jun2010")) && !verbs.contains("d3dx9") {
                verbs.append("d3dx9")
            }
        }
        return verbs
    }
}

/// Finds Windows programs worth launching, ranked so the game itself usually comes first.
public enum ProgramFinder {
    /// Folders Wine creates in every prefix, and folders of redistributables and tools.
    static let skippedFolders: Set<String> = [
        "windows", "programdata", "users", "common files", "internet explorer", "windows media player",
        "windows nt", "windowspowershell", "_commonredist", "redist", "redistributables", "directx",
        "dotnetfx", "vcredist", "support", "__installer", "installers", "easyanticheat", "battleye",
    ]

    static let skippedNamePrefixes = [
        "unins", "uninst", "setup", "install", "vcredist", "vc_redist", "dxsetup", "dotnet", "ndp",
        "unitycrashhandler", "crashreport", "crashpad", "crs-", "ue4prereq", "ueprereq", "cefsharp", "notification_helper",
        "quicksfv", "dxwebsetup", "oalinst", "physx", "start_protected_game",
    ]

    public static func find(in folder: URL, limit: Int = 50) -> [DiscoveredProgram] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        // Resolve a linked game folder so its contents are searched.
        let root = folder.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        var found: [DiscoveredProgram] = []
        for case let url as URL in enumerator {
            if enumerator.level > 7 { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent.lowercased()
            if values?.isDirectory == true {
                if skippedFolders.contains(name) { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  !skippedNamePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let components = Array(url.standardizedFileURL.pathComponents.dropFirst(rootDepth))
            let size = Int64(values?.fileSize ?? 0)
            found.append(DiscoveredProgram(
                relativePath: components.joined(separator: "/"),
                url: url,
                size: size,
                score: score(name: name, depth: components.count, size: size, folderName: root.lastPathComponent)
            ))
        }
        return Array(found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.relativePath < $1.relativePath }.prefix(limit))
    }

    static func score(name: String, depth: Int, size: Int64, folderName: String) -> Int {
        var score = 0
        if name.hasSuffix("-win64-shipping.exe") || name.hasSuffix("-shipping.exe") { score += 60 }
        if name.contains("launcher") || name.contains("config") || name.contains("settings") || name.contains("editor") { score -= 25 }
        if name.contains("server") || name.contains("benchmark") || name.contains("report") || name.contains("helper") { score -= 20 }
        let stem = name.replacingOccurrences(of: ".exe", with: "").filter { $0.isLetter || $0.isNumber }
        let folder = folderName.lowercased().filter { $0.isLetter || $0.isNumber }
        if !stem.isEmpty, !folder.isEmpty, folder.contains(stem) || stem.contains(folder) { score += 30 }
        score -= max(0, depth - 1) * 3
        // Bigger executables are more often the game: 1 point per 4 MB, up to 30.
        score += Int(min(size / 4_000_000, 30))
        return score
    }
}
