import Foundation

/// A bounds-checked reader for DER, the ASN.1 encoding of certificates and signatures. It only
/// splits the encoding into tag-length-value elements; meaning is up to the caller. Untrusted
/// input (a downloaded program's signature) can't make it read outside the data: every length
/// is checked, and indefinite lengths (BER, not DER) are refused.
struct DERElement {
    let tag: UInt8
    /// The whole element: tag, length and value.
    let encoded: Range<Int>
    /// Its value.
    let value: Range<Int>

    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    static let oid: UInt8 = 0x06
    static let octetString: UInt8 = 0x04
    static let integer: UInt8 = 0x02

    /// Context-specific constructed tag `[n]`.
    static func context(_ n: UInt8) -> UInt8 { 0xA0 | n }
}

struct DERReader {
    let data: Data

    init(_ data: Data) {
        // Work with zero-based offsets whatever slice this came from.
        self.data = Data(data)
    }

    /// The element starting at `offset`, within `limit` (the end of its parent).
    func element(at offset: Int, limit: Int? = nil) -> DERElement? {
        let end = min(limit ?? data.count, data.count)
        guard offset >= 0, offset + 2 <= end else { return nil }
        let tag = data[offset]
        guard tag & 0x1F != 0x1F else { return nil }          // multi-byte tags: not used here
        var cursor = offset + 1
        let first = data[cursor]
        cursor += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count >= 1, count <= 4, cursor + count <= end else { return nil }   // no indefinite lengths
            for _ in 0..<count {
                length = (length << 8) | Int(data[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= end else { return nil }
        return DERElement(tag: tag, encoded: offset..<(cursor + length), value: cursor..<(cursor + length))
    }

    /// The elements directly inside `parent`'s value.
    func children(of parent: DERElement) -> [DERElement]? {
        var result: [DERElement] = []
        var cursor = parent.value.lowerBound
        while cursor < parent.value.upperBound {
            guard let child = element(at: cursor, limit: parent.value.upperBound) else { return nil }
            result.append(child)
            cursor = child.encoded.upperBound
        }
        return result
    }

    func bytes(_ range: Range<Int>) -> Data { data.subdata(in: range) }
    func value(_ element: DERElement) -> Data { bytes(element.value) }
    func encoded(_ element: DERElement) -> Data { bytes(element.encoded) }
}

/// Object identifiers used in Authenticode signatures, as DER value bytes.
enum OID {
    static let signedData = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])          // 1.2.840.113549.1.7.2
    static let spcIndirectData = Data([0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04]) // 1.3.6.1.4.1.311.2.1.4
    static let messageDigest = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04])       // 1.2.840.113549.1.9.4
    static let contentType = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03])         // 1.2.840.113549.1.9.3
    static let codeSigning = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])               // 1.3.6.1.5.5.7.3.3
    static let sha1 = Data([0x2B, 0x0E, 0x03, 0x02, 0x1A])                                         // 1.3.14.3.2.26
    static let sha256 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])             // 2.16.840.1.101.3.4.2.1
    static let sha384 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02])
    static let sha512 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03])
}
