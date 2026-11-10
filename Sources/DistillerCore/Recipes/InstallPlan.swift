import Foundation

/// One step of an install, as the player sees it: "Installing .NET Framework 4.8".
public struct InstallTask: Sendable, Equatable, Identifiable {
    /// Its position, from 1; `InstallProgress.step` refers to it.
    public var id: Int
    public var title: String
    /// Shown while it runs, for steps that take long or need the player.
    public var note: String?

    public init(id: Int, title: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
    }
}

/// Every step of an install, known before it starts, so the player can see what's coming,
/// what's done and what's running: creating the bottle, the prefix settings, each winetricks
/// component on its own, then the recipe's install steps. `RecipeInstaller` and
/// `DistillerEngine.install` report progress in this order.
public enum InstallPlan {
    /// The steps that configure a prefix (`RecipeInstaller.configurePrefix`).
    public static func configureTasks(_ resolved: ResolvedRecipe) -> [(title: String, note: String?)] {
        [
            ("Setting Windows to \(windowsName(resolved.windowsVersion))", nil),
            ("Applying registry settings", nil),
            ("Adding \(resolved.graphics.displayName)", nil),
        ] + resolved.winetricks.map { component($0) }
    }

    /// The whole install of a new game.
    public static func tasks(for resolved: ResolvedRecipe) -> [InstallTask] {
        let titles: [(title: String, note: String?)] = [("Creating a bottle", nil)]
            + configureTasks(resolved)
            + resolved.install.map { step($0) }
        return titles.enumerated().map { InstallTask(id: $0.offset + 1, title: $0.element.title, note: $0.element.note) }
    }

    static let slowNote = "This can take 30 minutes or more, and nothing appears on screen while it runs. Distiller is still working; please let it finish."

    /// A winetricks component, by what it is.
    public static func component(_ verb: String) -> (title: String, note: String?) {
        let names: [String: String] = [
            "corefonts": "Microsoft core fonts", "tahoma": "the Tahoma font",
            "dotnet40": ".NET Framework 4.0", "dotnet45": ".NET Framework 4.5", "dotnet472": ".NET Framework 4.7.2",
            "dotnet48": ".NET Framework 4.8", "dotnetdesktop6": ".NET Desktop Runtime 6", "dotnetdesktop8": ".NET Desktop Runtime 8",
            "d3dcompiler_43": "the Direct3D shader compiler (43)", "d3dcompiler_46": "the Direct3D shader compiler (46)",
            "d3dcompiler_47": "the Direct3D shader compiler (47)", "d3dx9": "DirectX 9 extras (D3DX9)",
            "d3dx10": "DirectX 10 extras (D3DX10)", "d3dx11_42": "DirectX 11 extras (D3DX11 42)", "d3dx11_43": "DirectX 11 extras (D3DX11 43)",
            "xact": "XACT audio", "xact_x64": "XACT audio (64-bit)", "xinput": "XInput for controllers", "physx": "PhysX",
            "faudio": "FAudio", "openal": "OpenAL", "mfc42": "MFC 4.2", "mfc140": "MFC 14",
            "msxml3": "MSXML 3", "msxml6": "MSXML 6", "quartz": "DirectShow (quartz)", "devenum": "DirectShow's device enumerator",
        ]
        var name = names[verb] ?? verb
        if verb.hasPrefix("vcrun") { name = "the Visual C++ \(verb.dropFirst(5)) runtime" }
        let note: String?
        if ["dotnet40", "dotnet45", "dotnet472", "dotnet48"].contains(verb) {
            note = slowNote
        } else if verb.hasPrefix("dotnetdesktop") || verb == "corefonts" {
            note = "This can take several minutes."
        } else {
            note = nil
        }
        return ("Installing \(name)", note)
    }

    static func step(_ step: InstallStep) -> (title: String, note: String?) {
        switch step {
        case .download(let download):
            return ("Downloading \(fileName(download.to))", nil)
        case .userDownload(let download):
            return ("Checking the installer you downloaded (\(fileName(download.to)))", nil)
        case .userFile(let file):
            return ("Copying your file (\(fileName(file.to)))", nil)
        case .userFolder(let folder):
            return ("Adding your folder (\(fileName(folder.to)))", nil)
        case .extract(let extract):
            return ("Extracting \(fileName(extract.archive))", nil)
        case .copy(let copy):
            return ("Copying \(fileName(copy.from))", nil)
        case .registry:
            return ("Applying registry settings", nil)
        case .dllOverride:
            return ("Setting DLL overrides", nil)
        case .winetricks(let verbs):
            return ("Installing \(verbs.map { component($0).title.replacingOccurrences(of: "Installing ", with: "") }.joined(separator: ", "))",
                    verbs.contains { component($0).note == slowNote } ? slowNote : nil)
        case .runWindows(let run):
            // An MSI runs through msiexec; name the package rather than msiexec.
            let isMSI = fileName(run.path).lowercased() == "msiexec.exe"
            let name = isMSI ? (run.args?.first { $0.lowercased().hasSuffix(".msi") }).map(fileName) ?? "the installer" : fileName(run.path)
            let note = run.wait == false ? nil
                : "Follow the installer's window if it shows one. If it starts a launcher or the game, the install finishes once that's running."
            return ("Running \(name)", note)
        }
    }

    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    static func windowsName(_ version: String) -> String {
        let names = ["win11": "Windows 11", "win10": "Windows 10", "win81": "Windows 8.1", "win8": "Windows 8",
                     "win7": "Windows 7", "vista": "Windows Vista", "winxp": "Windows XP", "winxp64": "Windows XP (64-bit)"]
        return names[version.lowercased()] ?? version
    }
}

/// Lets the player stop an install. Cancelling stops every program in the new bottle (which
/// ends the step that's running) and the install removes the bottle.
public final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stop: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !cancelled else { return nil }
            cancelled = true
            return stop
        }
        action?()
    }

    /// What stops the running step; runs at once if the install was already cancelled.
    func onCancel(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            stop = action
            return cancelled
        }
        if runNow { action() }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
