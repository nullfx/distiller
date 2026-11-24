import Foundation

/// Sets string values in a bottle's `user.reg` (HKEY_CURRENT_USER) directly, for settings Wine
/// reads when it starts (the macOS driver's keyboard options) and that must be applied before
/// every launch: going through Wine's registry tool would mean waiting for the bottle to be
/// idle, which never happens while a launcher runs. Wine reads the file when its server starts
/// and writes it back when it saves, so a change made while the bottle is running applies from
/// its next start. The file is replaced atomically; nothing else in it changes.
enum UserRegistryFile {
    /// Sets `values` in `key` (a path under HKEY_CURRENT_USER, such as `Software\Wine\Mac Driver`),
    /// adding the key if it isn't there. Returns false (doing nothing) when the file doesn't exist
    /// yet or already has these values.
    @discardableResult
    static func set(_ values: [(name: String, value: String)], key: String, in file: URL, now: Date = Date()) throws -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let updated = setting(values, key: key, in: text, now: now)
        guard updated != text else { return false }
        try updated.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func setting(_ values: [(name: String, value: String)], key: String, in text: String, now: Date) -> String {
        var lines = text.components(separatedBy: "\n")
        let header = "[" + escaped(key) + "]"
        let line = { (name: String, value: String) in "\"\(escaped(name))\"=\"\(escaped(value))\"" }
        guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) else {
            // Wine keeps keys sorted, but reads them in any order.
            let seconds = Int(now.timeIntervalSince1970)
            let filetime = String(UInt64(now.timeIntervalSince1970 + 11_644_473_600) * 10_000_000, radix: 16)
            var section = ["", "\(header) \(seconds)", "#time=\(filetime)"] + values.map(line)
            if lines.last == "" { lines.removeLast() } else { section.append("") }
            return (lines + section + [""]).joined(separator: "\n")
        }
        var end = lines.index(after: start)
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        // The section's last line before the blank line that separates sections.
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        for (name, value) in values {
            let prefix = "\"\(escaped(name))\"="
            if let existing = (start + 1..<insertAt).first(where: { lines[$0].lowercased().hasPrefix(prefix.lowercased()) }) {
                lines[existing] = line(name, value)
            } else {
                lines.insert(line(name, value), at: insertAt)
                insertAt += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
