import Foundation

/// Keeps the Logs folder in check: removes logs older than the retention period, then the
/// oldest until the folder is under its size limit (Settings ▸ Storage ▸ Logs). Each launch
/// log is already capped as it's written (`LaunchLog`); this keeps many of them from adding
/// up. Logs written to in the last hour are never removed: a game or check may still be
/// writing them.
public enum LogCleaner {
    public struct LogFile: Equatable, Sendable {
        public var url: URL
        public var size: Int64
        public var modified: Date

        public init(url: URL, size: Int64, modified: Date) {
            self.url = url
            self.size = size
            self.modified = modified
        }
    }

    public struct Usage: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
        public var oldest: Date?
    }

    public struct Result: Equatable, Sendable {
        public var removed: Int
        public var freedBytes: Int64
    }

    /// Logs this recent are kept whatever the settings say.
    public static let activeWindow: TimeInterval = 60 * 60

    /// The log files in `folder` (`*.log`, not in subfolders).
    public static func files(in folder: URL) -> [LogFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "log", let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return LogFile(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    public static func usage(of files: [LogFile]) -> Usage {
        Usage(files: files.count, bytes: files.reduce(0) { $0 + $1.size }, oldest: files.map(\.modified).min())
    }

    /// Which logs to remove: those older than `retentionDays` (0 keeps them), then the oldest
    /// until the rest fit in `limitBytes` (0 means no limit). Logs modified within
    /// `activeWindow` of `now` are always kept, and count towards the limit.
    public static func plan(_ files: [LogFile], now: Date, retentionDays: Int, limitBytes: Int64) -> [LogFile] {
        let active = { (file: LogFile) in now.timeIntervalSince(file.modified) < activeWindow }
        var remove: [LogFile] = []
        var kept = files.sorted { $0.modified < $1.modified }   // oldest first
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            remove = kept.filter { $0.modified < cutoff && !active($0) }
            kept.removeAll { file in remove.contains(file) }
        }
        if limitBytes > 0 {
            var total = kept.reduce(0) { $0 + $1.size }
            for file in kept where total > limitBytes && !active(file) {
                remove.append(file)
                total -= file.size
            }
        }
        return remove
    }

    /// Removes what `plan` chooses from `folder`.
    @discardableResult
    public static func clean(_ folder: URL, retentionDays: Int, limitMB: Int, now: Date = Date()) -> Result {
        let doomed = plan(files(in: folder), now: now, retentionDays: retentionDays, limitBytes: Int64(limitMB) * 1024 * 1024)
        var result = Result(removed: 0, freedBytes: 0)
        for file in doomed where (try? FileManager.default.removeItem(at: file.url)) != nil {
            result.removed += 1
            result.freedBytes += file.size
        }
        return result
    }
}

extension DistillerEngine {
    /// How much the Logs folder holds now.
    public func logUsage() -> LogCleaner.Usage {
        LogCleaner.usage(of: LogCleaner.files(in: paths.logs))
    }

    /// Cleans the Logs folder with the settings in `settings.json`.
    @discardableResult
    public func cleanLogs(now: Date = Date()) -> LogCleaner.Result {
        let settings = StorageSettings.load(fromSupportFolder: paths.root)
        return LogCleaner.clean(paths.logs, retentionDays: settings.effectiveLogRetentionDays, limitMB: settings.effectiveLogLimitMB, now: now)
    }
}
