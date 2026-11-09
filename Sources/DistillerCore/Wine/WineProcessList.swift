import Foundation

/// A Windows program running in a bottle, as its own Wine reports it.
public struct RunningWindowsProgram: Equatable, Hashable, Sendable {
    /// Wine's process ID (not a macOS one).
    public var pid: Int
    /// Such as `C:\Program Files\Example\Game.exe`.
    public var windowsPath: String

    public init(pid: Int, windowsPath: String) {
        self.pid = pid
        self.windowsPath = windowsPath
    }

    /// The file name, such as `Game.exe`.
    public var name: String {
        windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? windowsPath
    }

    /// Wine's own programs (services, the desktop, the process list itself), everything under
    /// `C:\windows`. They run in every bottle and are never the game.
    public var isWineSystemProgram: Bool {
        windowsPath.lowercased().replacingOccurrences(of: "/", with: "\\").hasPrefix("c:\\windows\\")
    }
}

/// Lists what's running in one bottle. Asking that bottle's Wine (`wmic process get
/// ExecutablePath,ProcessId`) keeps the answer to that bottle, even while other bottles run;
/// macOS's own process list shows Windows paths but not which bottle they belong to.
public enum WineProcessList {
    /// The arguments for Wine.
    static let wmicArguments = ["wmic.exe", "process", "get", "ExecutablePath,ProcessId"]

    /// wmic's output as text. Redirected to a file (as Distiller reads it), Wine's wmic writes
    /// UTF-16 with a byte-order mark, like Windows; on a terminal it writes plain text.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes == [0xFE, 0xFF] { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Parses wmic's table: a header naming the columns, then one row per process. The process
    /// ID is each row's last word and the path everything before it, so paths with spaces
    /// (even double ones) survive whatever the column widths. Anything before the header
    /// (Wine's diagnostics) is ignored.
    public static func parse(_ output: String) -> [RunningWindowsProgram] {
        let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: {
            let lower = $0.lowercased()
            return lower.hasPrefix("executablepath") && lower.contains("processid")
        }) else { return [] }

        var programs: [RunningWindowsProgram] = []
        for line in lines[(headerIndex + 1)...] {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard let gap = row.lastIndex(of: " ") else { continue }
            let path = row[..<gap].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, let pid = Int(row[row.index(after: gap)...]) else { continue }
            programs.append(RunningWindowsProgram(pid: pid, windowsPath: path))
        }
        return programs
    }
}
