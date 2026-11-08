import Foundation

/// Renders registry edits as a .reg file for `wine regedit /S`.
public enum RegistryFile {
    public static func render(_ edits: [RegistryEdit]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for edit in edits {
            lines.append("[\(expandHive(edit.key))]")
            for name in edit.values.keys.sorted() {
                guard let value = edit.values[name] else { continue }
                switch value {
                case .string(let text):
                    lines.append("\"\(escape(name))\"=\"\(escape(text))\"")
                case .dword(let number):
                    lines.append("\"\(escape(name))\"=dword:\(String(format: "%08x", number))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// UTF-16 little-endian with a byte-order mark, the encoding regedit expects for version 5 files.
    public static func data(_ edits: [RegistryEdit]) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(render(edits).data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    public static func expandHive(_ key: String) -> String {
        let normalized = key.replacingOccurrences(of: "/", with: "\\")
        for (short, long) in [("HKCU\\", "HKEY_CURRENT_USER\\"), ("HKLM\\", "HKEY_LOCAL_MACHINE\\")] {
            if normalized.uppercased().hasPrefix(short) {
                return long + normalized.dropFirst(short.count)
            }
        }
        return normalized
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
