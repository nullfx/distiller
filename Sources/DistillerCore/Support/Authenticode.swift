import CryptoKit
import Foundation
import Security

/// A Windows program's verified Authenticode signature.
public struct AuthenticodeSignature: Equatable, Sendable {
    /// The signing certificate's common name, such as "Example Publisher, Inc.".
    public var signer: String
    /// "SHA-256", "SHA-1", …: what the publisher signed the program's contents with.
    public var digestAlgorithm: String
}

public enum AuthenticodeError: LocalizedError, Equatable {
    case notAWindowsProgram
    case unsigned
    case malformed(String)
    /// The program's contents don't match what was signed: it was changed after signing.
    case contentsChanged
    case badSignature
    /// The certificate chain doesn't lead to a trusted root (or has expired), with the reason.
    case untrusted(String)
    case notForCodeSigning
    case wrongSigner(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .notAWindowsProgram: return "It isn't a Windows program."
        case .unsigned: return "It isn't signed by its publisher."
        case .malformed(let what): return "Its signature can't be read (\(what))."
        case .contentsChanged: return "It was changed after its publisher signed it."
        case .badSignature: return "Its signature doesn't verify."
        case .untrusted(let reason): return "Its signing certificate isn't trusted: \(reason)"
        case .notForCodeSigning: return "Its certificate isn't one for signing programs."
        case .wrongSigner(let expected, let found): return "It's signed by \(found), not \(expected)."
        }
    }
}

/// Verifies the Authenticode signature Windows programs carry, for installers whose contents
/// change with every update (so a pinned checksum can't describe them) but which their
/// publisher always signs. Written from Microsoft's published Authenticode specification
/// ("Windows Authenticode Portable Executable Signature Format") and PKCS #7 (RFC 2315).
///
/// It checks, in order: the program's contents hash to the digest that was signed (the
/// file minus its checksum, its certificate-table entry and the table); the signed
/// attributes carry that digest's own hash; the signature over them verifies with the signing
/// certificate's key; the certificate chain leads to a root macOS trusts (or to `anchors`, for
/// tests); and the certificate is for code signing. Parsing is bounds-checked throughout.
///
/// Not checked yet: timestamp countersignatures, so a signature made with a certificate that
/// has since expired is reported as untrusted.
public enum Authenticode {
    public static func verify(_ url: URL, expectedSigner: String? = nil, anchors: [SecCertificate]? = nil, date: Date = Date()) throws -> AuthenticodeSignature {
        let data: Data
        do { data = try Data(contentsOf: url, options: [.alwaysMapped]) } catch { throw AuthenticodeError.notAWindowsProgram }
        return try verify(data: data, expectedSigner: expectedSigner, anchors: anchors, date: date)
    }

    public static func verify(data: Data, expectedSigner: String? = nil, anchors: [SecCertificate]? = nil, date: Date = Date()) throws -> AuthenticodeSignature {
        let file = Data(data)
        guard let image = PEImage(data: file) else { throw AuthenticodeError.notAWindowsProgram }
        let layout = try certificateTable(in: image, size: file.count)
        let signature = try SignedData(DERReader(layout.blob))

        // 1. The program's contents are what was signed.
        let imageDigest = try hash(file, excluding: layout, algorithm: signature.indirectDigestAlgorithm)
        guard imageDigest == signature.indirectDigest else { throw AuthenticodeError.contentsChanged }

        // 2. The signed attributes carry the hash of the signed content (its value, without
        //    the outer header: PKCS #7 hashes a content's contents).
        guard try digest(signature.contentValue, algorithm: signature.signerDigestAlgorithm) == signature.messageDigest else {
            throw AuthenticodeError.badSignature
        }

        // 3. The signature over the attributes verifies with the signing certificate's key.
        guard let certificate = SecCertificateCreateWithData(nil, signature.signerCertificate as CFData),
              let key = SecCertificateCopyKey(certificate) else { throw AuthenticodeError.malformed("signing certificate") }
        let algorithm = try signatureAlgorithm(for: key, digest: signature.signerDigestAlgorithm)
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, algorithm, signature.signedAttributes as CFData, signature.encryptedDigest as CFData, &error) else {
            throw AuthenticodeError.badSignature
        }

        // 4. The chain leads to a trusted root, at `date`.
        let others = signature.certificates.filter { $0 != signature.signerCertificate }.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(([certificate] + others) as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            throw AuthenticodeError.untrusted("its certificates can't be checked")
        }
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, date as CFDate)
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            throw AuthenticodeError.untrusted(trustError.map { CFErrorCopyDescription($0) as String } ?? "no reason given")
        }

        // 5. It's a code-signing certificate, from the signer the recipe names.
        guard isForCodeSigning(certificate) else { throw AuthenticodeError.notForCodeSigning }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        let signer = (name as String?) ?? ""
        if let expectedSigner, signer.compare(expectedSigner, options: [.caseInsensitive]) != .orderedSame {
            throw AuthenticodeError.wrongSigner(expected: expectedSigner, found: signer.isEmpty ? "an unnamed signer" : signer)
        }
        return AuthenticodeSignature(signer: signer, digestAlgorithm: signature.indirectDigestAlgorithm.name)
    }

    // MARK: The program

    struct TableLayout {
        var checksumOffset: Int
        var directoryEntryOffset: Int
        var tableOffset: Int
        var tableSize: Int
        var blob: Data
    }

    /// The certificate table (data directory 4, whose address is a file offset) and its first
    /// certificate, which must be a PKCS #7 signature (WIN_CERT_TYPE_PKCS_SIGNED_DATA).
    static func certificateTable(in image: PEImage, size: Int) throws -> TableLayout {
        guard image.directoryCount > 4 else { throw AuthenticodeError.unsigned }
        let entry = image.directoriesOffset + 4 * 8
        guard let offset = image.reader.u32(entry).map(Int.init), let length = image.reader.u32(entry + 4).map(Int.init),
              offset > 0, length > 0 else { throw AuthenticodeError.unsigned }
        guard offset >= entry + 8, offset <= size, length <= size - offset else { throw AuthenticodeError.malformed("certificate table") }
        guard let certificateLength = image.reader.u32(offset).map(Int.init), let type = image.reader.u16(offset + 6),
              certificateLength > 8, certificateLength <= length else { throw AuthenticodeError.malformed("certificate entry") }
        guard type == 0x0002 else { throw AuthenticodeError.malformed("not a PKCS #7 signature") }
        guard let blob = image.reader.bytes(offset + 8, count: certificateLength - 8) else { throw AuthenticodeError.malformed("certificate entry") }
        return TableLayout(checksumOffset: image.optionalHeaderOffset + 64, directoryEntryOffset: entry,
                           tableOffset: offset, tableSize: length, blob: blob)
    }

    /// The Authenticode digest: the whole file except its checksum, its certificate-table
    /// entry and the certificate table.
    static func hash(_ file: Data, excluding layout: TableLayout, algorithm: DigestAlgorithm) throws -> Data {
        let ranges = [
            0..<layout.checksumOffset,
            (layout.checksumOffset + 4)..<layout.directoryEntryOffset,
            (layout.directoryEntryOffset + 8)..<layout.tableOffset,
            (layout.tableOffset + layout.tableSize)..<file.count,
        ]
        guard ranges.allSatisfy({ $0.lowerBound <= $0.upperBound && $0.upperBound <= file.count }) else {
            throw AuthenticodeError.malformed("headers")
        }
        return digest(ranges.map { file.subdata(in: $0) }, algorithm: algorithm)
    }

    // MARK: Hashes and keys

    enum DigestAlgorithm: Equatable {
        case sha1, sha256, sha384, sha512

        init(oid: Data) throws {
            switch oid {
            case OID.sha1: self = .sha1
            case OID.sha256: self = .sha256
            case OID.sha384: self = .sha384
            case OID.sha512: self = .sha512
            default: throw AuthenticodeError.malformed("an unknown digest algorithm")
            }
        }

        var name: String {
            switch self {
            case .sha1: return "SHA-1"
            case .sha256: return "SHA-256"
            case .sha384: return "SHA-384"
            case .sha512: return "SHA-512"
            }
        }
    }

    static func digest(_ data: Data, algorithm: DigestAlgorithm) throws -> Data { digest([data], algorithm: algorithm) }

    static func digest(_ parts: [Data], algorithm: DigestAlgorithm) -> Data {
        func run<H: HashFunction>(_ hash: H) -> Data {
            var hash = hash
            for part in parts { hash.update(data: part) }
            return Data(hash.finalize())
        }
        switch algorithm {
        case .sha1: return run(Insecure.SHA1())
        case .sha256: return run(SHA256())
        case .sha384: return run(SHA384())
        case .sha512: return run(SHA512())
        }
    }

    static func signatureAlgorithm(for key: SecKey, digest: DigestAlgorithm) throws -> SecKeyAlgorithm {
        let type = (SecKeyCopyAttributes(key) as? [CFString: Any])?[kSecAttrKeyType] as? String
        if type == (kSecAttrKeyTypeRSA as String) {
            switch digest {
            case .sha1: return .rsaSignatureMessagePKCS1v15SHA1
            case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
            case .sha384: return .rsaSignatureMessagePKCS1v15SHA384
            case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
            }
        }
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch digest {
            case .sha1: return .ecdsaSignatureMessageX962SHA1
            case .sha256: return .ecdsaSignatureMessageX962SHA256
            case .sha384: return .ecdsaSignatureMessageX962SHA384
            case .sha512: return .ecdsaSignatureMessageX962SHA512
            }
        }
        throw AuthenticodeError.malformed("an unsupported key type")
    }

    static func isForCodeSigning(_ certificate: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDExtendedKeyUsage] as CFArray, nil) as? [CFString: Any],
              let usage = values[kSecOIDExtendedKeyUsage] as? [CFString: Any],
              let purposes = usage[kSecPropertyKeyValue] as? [Data] else { return false }
        return purposes.contains(OID.codeSigning)
    }
}

/// The parts of a PKCS #7 SignedData Authenticode signature that verification needs.
struct SignedData {
    var contentValue: Data                 // SpcIndirectDataContent's value bytes
    var indirectDigest: Data                // the program digest that was signed
    var indirectDigestAlgorithm: Authenticode.DigestAlgorithm
    var certificates: [Data]               // DER certificates carried in the signature
    var signerCertificate: Data
    var signerDigestAlgorithm: Authenticode.DigestAlgorithm
    var signedAttributes: Data             // re-tagged as a SET, as they were signed
    var messageDigest: Data
    var encryptedDigest: Data

    init(_ der: DERReader) throws {
        func fail(_ what: String) -> AuthenticodeError { .malformed(what) }
        func kids(_ element: DERElement?, _ tag: UInt8 = DERElement.sequence) throws -> [DERElement] {
            guard let element, element.tag == tag, let children = der.children(of: element) else { throw fail("structure") }
            return children
        }

        // ContentInfo { contentType signedData, [0] SignedData }
        let contentInfo = try kids(der.element(at: 0))
        func oid(_ element: DERElement) -> Data? { element.tag == DERElement.oid ? der.value(element) : nil }
        guard contentInfo.count >= 2, oid(contentInfo[0]) == OID.signedData,
              contentInfo[1].tag == DERElement.context(0) else { throw fail("not signed data") }
        let signedData = try kids(try kids(contentInfo[1], DERElement.context(0)).first)
        guard signedData.count >= 4 else { throw fail("signed data") }

        // contentInfo { spcIndirectData, [0] SpcIndirectDataContent }
        let encapsulated = try kids(signedData[2])
        guard encapsulated.count == 2, oid(encapsulated[0]) == OID.spcIndirectData,
              encapsulated[1].tag == DERElement.context(0),
              let content = try kids(encapsulated[1], DERElement.context(0)).first, content.tag == DERElement.sequence else { throw fail("not an Authenticode signature") }
        contentValue = der.value(content)
        // SpcIndirectDataContent { data, messageDigest DigestInfo { algorithm, digest } }
        let indirect = try kids(content)
        guard indirect.count == 2 else { throw fail("indirect data") }
        let digestInfo = try kids(indirect[1])
        guard digestInfo.count == 2, let algorithm = try kids(digestInfo[0]).first, digestInfo[1].tag == DERElement.octetString else {
            throw fail("digest")
        }
        indirectDigestAlgorithm = try Authenticode.DigestAlgorithm(oid: oid(algorithm) ?? Data())
        indirectDigest = der.value(digestInfo[1])

        // [0] IMPLICIT certificates, then (optionally [1] CRLs, then) signerInfos.
        guard let certificateSet = signedData.first(where: { $0.tag == DERElement.context(0) }) else { throw fail("certificates") }
        certificates = try kids(certificateSet, DERElement.context(0)).map { der.encoded($0) }
        guard let signerInfos = signedData.last, signerInfos.tag == DERElement.set,
              let signerInfo = try kids(signerInfos, DERElement.set).first else { throw fail("signer") }

        // SignerInfo { version, issuerAndSerialNumber, digestAlgorithm, [0] authenticatedAttributes,
        //              digestEncryptionAlgorithm, encryptedDigest, [1] unauthenticatedAttributes }
        let signer = try kids(signerInfo)
        guard signer.count >= 6 else { throw fail("signer") }
        let issuerAndSerial = try kids(signer[1])
        guard issuerAndSerial.count == 2, issuerAndSerial[1].tag == DERElement.integer else { throw fail("signer identity") }
        let issuer = der.encoded(issuerAndSerial[0])
        let serial = der.value(issuerAndSerial[1])
        guard let digestAlgorithm = try kids(signer[2]).first else { throw fail("signer digest") }
        signerDigestAlgorithm = try Authenticode.DigestAlgorithm(oid: oid(digestAlgorithm) ?? Data())
        guard signer[3].tag == DERElement.context(0) else { throw fail("signed attributes") }
        var attributes = der.encoded(signer[3])
        attributes[attributes.startIndex] = DERElement.set
        signedAttributes = attributes
        guard signer[5].tag == DERElement.octetString else { throw fail("signature") }
        encryptedDigest = der.value(signer[5])

        var found: Data?
        for attribute in try kids(signer[3], DERElement.context(0)) {
            let parts = try kids(attribute)
            guard parts.count == 2, parts[0].tag == DERElement.oid, der.value(parts[0]) == OID.messageDigest,
                  let value = try kids(parts[1], DERElement.set).first, value.tag == DERElement.octetString else { continue }
            found = der.value(value)
        }
        guard let found else { throw fail("message digest") }
        messageDigest = found

        // The signing certificate: the one whose issuer and serial number the signer names.
        let signing = certificates.first { certificate in
            let reader = DERReader(certificate)
            guard let tbs = reader.element(at: 0).flatMap(reader.children)?.first, let fields = reader.children(of: tbs) else { return false }
            let start = fields.first?.tag == DERElement.context(0) ? 1 : 0     // optional [0] version
            guard fields.count > start + 2 else { return false }
            return reader.value(fields[start]) == serial && reader.encoded(fields[start + 2]) == issuer
        }
        guard let signing else { throw fail("the signing certificate isn't included") }
        signerCertificate = signing
    }
}
