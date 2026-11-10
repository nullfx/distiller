import Foundation

/// Waits for "every program in the bottle to exit" (`wineserver -w`, which Distiller and
/// winetricks both use) that can never end: the .NET Framework installs a background service
/// that compiles its files (NGen, `mscorsvw.exe`), starts with the bottle and never exits. On
/// Windows it turns itself off once it's done; under Wine it doesn't, so a winetricks `dotnet40`
/// or `dotnet48` would wait forever after its installer finished.
///
/// When the only programs left in a bottle are Wine's own and such services, Distiller sets the
/// services to start only when asked and stops them, which ends the wait. Nothing is lost: the
/// compiling is an optimization, .NET programs run without it, and winetricks compiles what's
/// queued (`ngen executequeueditems`) when it installs .NET Framework 4.0.
public enum StuckWait {
    /// Wine's own programs that end by themselves once nothing else runs in the bottle.
    static let wineServices: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "lsass.exe",
        "explorer.exe", "conhost.exe", "wmic.exe", "start.exe",
    ]

    /// Background services that never exit, by program, with the service names that run it.
    static let neverExiting: [String: [String]] = [
        "mscorsvw.exe": ["clr_optimization_v4.0.30319_32", "clr_optimization_v4.0.30319_64"],
    ]

    /// How long a wait goes on before Distiller looks at what it's waiting for.
    static let patience: Duration = .seconds(30)

    /// The services to stop, when everything still running in the bottle is Wine's own or a
    /// service that never exits; empty while anything else (an installer, a game) runs.
    public static func servicesToStop(_ programs: [RunningWindowsProgram]) -> [String] {
        var services: [String] = []
        for program in programs {
            let name = program.name.lowercased()
            if wineServices.contains(name) { continue }
            guard let names = neverExiting[name] else { return [] }
            for service in names where !services.contains(service) { services.append(service) }
        }
        return services
    }

    /// One row of macOS's process list.
    struct HostProcess: Equatable {
        var pid: Int32
        var parent: Int32
        var command: String
    }

    /// Parses `ps -axo pid=,ppid=,command=`.
    static func parseProcessList(_ output: String) -> [HostProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return HostProcess(pid: pid, parent: parent, command: String(fields[2]))
        }
    }

    /// Whether a process started (directly or not) by `root` is waiting for the bottle's
    /// programs to exit: `wineserver -w`.
    static func isWaitingForServer(under root: Int32, in processes: [HostProcess]) -> Bool {
        var children: [Int32: [HostProcess]] = [:]
        for process in processes { children[process.parent, default: []].append(process) }
        var queue = children[root] ?? []
        var seen: Set<Int32> = [root]
        while let process = queue.popLast() {
            guard seen.insert(process.pid).inserted else { continue }
            let words = process.command.split(separator: " ")
            if words.first?.hasSuffix("wineserver") == true, words.dropFirst().contains("-w") { return true }
            queue += children[process.pid] ?? []
        }
        return false
    }
}

extension WineRunner {
    /// Stops the background services a wait is stuck on, if that's all that's left running in
    /// the bottle. Returns true if it stopped any.
    @discardableResult
    func releaseStuckWait(wine: InstalledComponent, environment: [String: String]) async -> Bool {
        guard let programs = try? await runningPrograms(wine: wine, environment: environment) else { return false }
        let services = StuckWait.servicesToStop(programs)
        guard !services.isEmpty else { return false }
        for service in services {
            // Either can fail harmlessly: a 32-bit-only bottle has no 64-bit service. Start = 3 is
            // "on demand"; Wine's `sc config` can't change it (it fails with code 103).
            try? await wineCommand(["reg", "add", #"HKLM\System\CurrentControlSet\Services\"# + service,
                                    "/v", "Start", "/t", "REG_DWORD", "/d", "3", "/f"],
                                   wine: wine, environment: environment, logName: "services")
            try? await wineCommand(["net", "stop", service], wine: wine, environment: environment, logName: "services")
        }
        return true
    }

    /// Whether winetricks (process `root`) is waiting for the bottle's programs to exit.
    func isWaitingForServer(under root: Int32) async -> Bool {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,ppid=,command="]) else {
            return false
        }
        return StuckWait.isWaitingForServer(under: root, in: StuckWait.parseProcessList(result.output))
    }
}
