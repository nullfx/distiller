import Foundation

/// Reads Battle.net's install database (`C:\ProgramData\Battle.net\Agent\product.db`), a
/// protobuf message: `repeated ProductInstall product_installs = 1`, each with
/// `string uid = 1`, `string product_code = 2` and `UserSettings settings = 3`, whose
/// `string install_path = 1` is the game's folder. Only those fields are read; everything else
/// is skipped. Bounds-checked: malformed input gives what was read so far.
enum ProductDatabase {
    struct Install: Equatable {
        var uid: String
        var productCode: String
        var installPath: String
    }

    static func installs(in data: Data) -> [Install] {
        var installs: [Install] = []
        for (field, value) in fields(of: [UInt8](data)) where field == 1 {
            guard case .bytes(let message) = value else { continue }
            var uid = "", code = "", path = ""
            for (inner, innerValue) in fields(of: message) {
                guard case .bytes(let bytes) = innerValue else { continue }
                switch inner {
                case 1: uid = String(decoding: bytes, as: UTF8.self)
                case 2: code = String(decoding: bytes, as: UTF8.self)
                case 3:
                    for (setting, settingValue) in fields(of: bytes) where setting == 1 {
                        if case .bytes(let pathBytes) = settingValue { path = String(decoding: pathBytes, as: UTF8.self) }
                    }
                default: break
                }
            }
            if !code.isEmpty, !path.isEmpty { installs.append(Install(uid: uid, productCode: code, installPath: path)) }
        }
        return installs
    }

    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        case fixed
    }

    /// The top-level fields of a protobuf message, in order.
    static func fields(of bytes: [UInt8]) -> [(Int, Value)] {
        var result: [(Int, Value)] = []
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint(), key >> 3 > 0, key >> 3 < 1 << 29 else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return result }
                result.append((field, .varint(value)))
            case 1:
                guard index + 8 <= bytes.count else { return result }
                index += 8
                result.append((field, .fixed))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return result }
                let end = index + Int(length)
                result.append((field, .bytes(Array(bytes[index..<end]))))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return result }
                index += 4
                result.append((field, .fixed))
            default:
                return result
            }
        }
        return result
    }
}
