import Foundation

/// Runs Wine commands against a prefix. Every command writes to a log in `Logs/`.
public final class WineRunner: @unchecked Sendable {
    public let paths: DistillerPaths

    public init(paths: DistillerPaths) {
        self.paths = paths
    }

    // MARK: Prefix setup

    /// Creates a fresh prefix with `wineboot --init` and waits for wineserver to finish.
    public func initializePrefix(_ prefix: URL, wine: InstalledComponent) async throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let env = WineEnvironment.build(prefix: prefix, wine: wine, graphics: nil, resolved: nil)
        try await wineCommand(["wineboot", "--init"], wine: wine, environment: env, logName: "wineboot")
        try await waitForServer(wine: wine, environment: env)
    }

    public func setWindowsVersion(_ version: String, wine: InstalledComponent, environment: [String: String]) async throws {
        try await wineCommand(["winecfg", "-v", version], wine: wine, environment: environment, logName: "winecfg")
        try await waitForServer(wine: wine, environment: environment)
    }

    public func importRegistry(_ edits: [RegistryEdit], prefix: URL, wine: InstalledComponent, environment: [String: String]) async throws {
        guard !edits.isEmpty else { return }
        let file = prefix.appendingPathComponent("drive_c/distiller-import.reg")
        try RegistryFile.data(edits).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        try await wineCommand(["regedit", "/S", "C:\\distiller-import.reg"], wine: wine, environment: environment, logName: "regedit")
        try await waitForServer(wine: wine, environment: environment)
    }

    public func runWinetricks(
        _ verbs: [String],
        winetricks: InstalledComponent,
        wine: InstalledComponent,
        environment: [String: String]
    ) async throws {
        guard !verbs.isEmpty else { return }
        try RecipePolicy.checkVerbs(verbs)
        guard let script = winetricks.scriptURL, let wineBinary = wine.wineBinary else {
            throw DistillerError.componentNotFound("winetricks")
        }
        var env = environment
        env["WINE"] = wineBinary.path
        env["WINESERVER"] = wine.wineserverBinary?.path
        let log = logURL(named: "winetricks")
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "-q"] + verbs,
            environment: env,
            logFile: log
        )
        guard result.status == 0 else {
            throw DistillerError.processFailed(command: "winetricks \(verbs.joined(separator: " "))", status: result.status, logFile: log.path)
        }
        try await waitForServer(wine: wine, environment: environment)
    }

    /// Runs a Windows program (an installer, usually) and waits for it.
    public func runWindowsProgram(
        _ program: URL,
        arguments: [String],
        wine: InstalledComponent,
        environment: [String: String],
        wait: Bool
    ) async throws {
        try await wineCommand(
            [program.path] + arguments,
            wine: wine,
            environment: environment,
            logName: "install-\(program.deletingPathExtension().lastPathComponent)",
            currentDirectory: program.deletingLastPathComponent()
        )
        if wait {
            try await waitForServer(wine: wine, environment: environment)
        }
    }

    // MARK: Playing

    /// Starts a program and returns immediately. `program` may be a host path or a name Wine
    /// knows, such as "notepad" or "winecfg".
    public func launch(
        program: String,
        arguments: [String],
        wine: InstalledComponent,
        environment: [String: String],
        workingDirectory: URL?,
        logName: String,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Process {
        guard let wineBinary = wine.wineBinary else {
            throw DistillerError.componentNotFound("a wine executable in \(wine.manifest.displayName)")
        }
        return try ProcessRunner.launch(
            wineBinary,
            arguments: [program] + arguments,
            environment: environment,
            currentDirectory: workingDirectory,
            logFile: logURL(named: logName),
            onExit: onExit
        )
    }

    /// The Windows programs running in the prefix named by `environment["WINEPREFIX"]`.
    /// Output goes through a file, not a pipe: if nothing was running, Wine starts its server,
    /// which would otherwise hold the pipe open.
    public func runningPrograms(wine: InstalledComponent, environment: [String: String]) async throws -> [RunningWindowsProgram] {
        guard let wineBinary = wine.wineBinary else {
            throw DistillerError.componentNotFound("a wine executable in \(wine.manifest.displayName)")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-wmic-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        var quiet = environment
        quiet["WINEDEBUG"] = "-all"
        _ = try await ProcessRunner.run(wineBinary, arguments: WineProcessList.wmicArguments, environment: quiet, logFile: output)
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return WineProcessList.parse(text)
    }

    /// Stops every Wine process in the prefix named by `environment["WINEPREFIX"]`.
    public func killAll(wine: InstalledComponent, environment: [String: String]) async throws {
        guard let server = wine.wineserverBinary else { return }
        _ = try await ProcessRunner.run(server, arguments: ["-k"], environment: environment, logFile: logURL(named: "wineserver"))
    }

    // MARK: Logs

    public func logURL(named name: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return paths.logs.appendingPathComponent("\(name)-\(stamp).log")
    }

    /// The newest log whose name starts with `name`.
    public func latestLog(named name: String) -> URL? {
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return logs
            .filter { $0.lastPathComponent.hasPrefix("\(name)-") }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
    }

    // MARK: Helpers

    func wineCommand(
        _ arguments: [String],
        wine: InstalledComponent,
        environment: [String: String],
        logName: String,
        currentDirectory: URL? = nil
    ) async throws {
        guard let wineBinary = wine.wineBinary else {
            throw DistillerError.componentNotFound("a wine executable in \(wine.manifest.displayName)")
        }
        let log = logURL(named: logName)
        let result = try await ProcessRunner.run(
            wineBinary, arguments: arguments, environment: environment, currentDirectory: currentDirectory, logFile: log
        )
        guard result.status == 0 else {
            throw DistillerError.processFailed(command: "wine \(arguments.first ?? "")", status: result.status, logFile: log.path)
        }
    }

    func waitForServer(wine: InstalledComponent, environment: [String: String]) async throws {
        guard let server = wine.wineserverBinary, FileManager.default.isExecutableFile(atPath: server.path) else { return }
        _ = try await ProcessRunner.run(server, arguments: ["-w"], environment: environment, logFile: logURL(named: "wineserver"))
    }
}
