import Foundation
import Security

/// Timestamps on Authenticode signatures: a timestamp authority's signature saying when the
/// program's signature was made, so the signing certificate can be checked as of that time
/// (Windows does the same). Two forms are read, from the signer's unsigned attributes:
///
/// - **RFC 3161 tokens** (Microsoft's attribute 1.3.6.1.4.1.311.3.3.1), used by current signing
///   tools: a CMS SignedData whose TSTInfo carries a hash of the signature and the time.
/// - **PKCS #9 countersignatures** (1.2.840.113549.1.9.6), the older form (Steam's installer
///   has one): a SignerInfo over the hash of the signature, with a signing-time attribute.
///
/// A timestamp counts only if: it vouches for this exact signature (the hash matches its
/// encrypted digest), its own signature verifies, it comes from a certificate issued for
/// timestamping, and that certificate's chain was trusted (and not revoked) at the time it
/// states. Anything else, it's ignored, which is never better for the program than having no
/// timestamp. Written from RFC 3161, RFC 5652 and PKCS #9 (RFC 2985).
enum AuthenticodeTimestamp {
    /// The time a valid timestamp on `signer`'s signature vouches for, or nil.
    static func signingTime(of signer: SignerInfoParts, certificates: [Data], anchors: [SecCertificate]?) -> Date? {
        for attribute in signer.unsignedAttributes {
            guard let value = attribute.values.first else { continue }
            if attribute.oid == OID.rfc3161Timestamp,
               let time = try? rfc3161(value, signature: signer.encryptedDigest, certificates: certificates, anchors: anchors) {
                return time
            }
            if attribute.oid == OID.countersignature,
               let time = try? countersignature(value, signature: signer.encryptedDigest, certificates: certificates, anchors: anchors) {
                return time
            }
        }
        return nil
    }

    /// A PKCS #9 countersignature: a SignerInfo whose message digest is the hash of the
    /// signature's encrypted digest, with the time in its signing-time attribute. Its
    /// certificate is among the signature's own.
    static func countersignature(_ value: Data, signature: Data, certificates: [Data], anchors: [SecCertificate]?) throws -> Date {
        let der = DERReader(value)
        guard let element = der.element(at: 0) else { throw AuthenticodeError.malformed("countersignature") }
        let counter = try SignerInfoParts(der, element)
        guard counter.messageDigest == Authenticode.digest([signature], algorithm: counter.digestAlgorithm) else {
            throw AuthenticodeError.badSignature
        }
        guard let (reader, timeElement) = counter.attribute(OID.signingTime), let time = Self.time(reader, timeElement) else {
            throw AuthenticodeError.malformed("countersignature time")
        }
        try checkAuthority(counter, certificates: certificates, anchors: anchors, at: time)
        return time
    }

    /// An RFC 3161 timestamp token: ContentInfo { signedData, SignedData { …, encapContentInfo
    /// { id-ct-TSTInfo, [0] OCTET STRING TSTInfo }, [0] certificates, …, signerInfos } }.
    static func rfc3161(_ value: Data, signature: Data, certificates outer: [Data], anchors: [SecCertificate]?) throws -> Date {
        func fail(_ what: String) -> AuthenticodeError { .malformed(what) }
        let der = DERReader(value)
        func kids(_ element: DERElement?, _ tag: UInt8 = DERElement.sequence) throws -> [DERElement] {
            guard let element, element.tag == tag, let children = der.children(of: element) else { throw fail("timestamp") }
            return children
        }
        let contentInfo = try kids(der.element(at: 0))
        guard contentInfo.count >= 2, contentInfo[0].tag == DERElement.oid, der.value(contentInfo[0]) == OID.signedData else {
            throw fail("timestamp")
        }
        let signedData = try kids(try kids(contentInfo[1], DERElement.context(0)).first)
        guard signedData.count >= 4 else { throw fail("timestamp") }
        let encapsulated = try kids(signedData[2])
        guard encapsulated.count == 2, encapsulated[0].tag == DERElement.oid, der.value(encapsulated[0]) == OID.tstInfo,
              let octets = try kids(encapsulated[1], DERElement.context(0)).first, octets.tag == DERElement.octetString else {
            throw fail("timestamp content")
        }
        let tstBytes = der.value(octets)

        // TSTInfo { version, policy, messageImprint { hashAlgorithm, hashedMessage }, serialNumber, genTime, … }
        let tst = DERReader(tstBytes)
        guard let tstElement = tst.element(at: 0), tstElement.tag == DERElement.sequence, let info = tst.children(of: tstElement),
              info.count >= 5, info[2].tag == DERElement.sequence, let imprint = tst.children(of: info[2]), imprint.count == 2,
              let algorithm = tst.children(of: imprint[0])?.first, algorithm.tag == DERElement.oid,
              imprint[1].tag == DERElement.octetString, let time = Self.time(tst, info[4]) else { throw fail("timestamp info") }
        let imprintAlgorithm = try Authenticode.DigestAlgorithm(oid: tst.value(algorithm))
        guard tst.value(imprint[1]) == Authenticode.digest([signature], algorithm: imprintAlgorithm) else {
            throw AuthenticodeError.badSignature
        }

        // The token's signer signs the TSTInfo (its message digest) and says it's one.
        guard let signerInfos = signedData.last, signerInfos.tag == DERElement.set,
              let signerElement = der.children(of: signerInfos)?.first else { throw fail("timestamp signer") }
        let signer = try SignerInfoParts(der, signerElement)
        guard signer.messageDigest == Authenticode.digest([tstBytes], algorithm: signer.digestAlgorithm) else {
            throw AuthenticodeError.badSignature
        }
        if let (reader, type) = signer.attribute(OID.contentType) {
            guard type.tag == DERElement.oid, reader.value(type) == OID.tstInfo else { throw fail("timestamp content type") }
        }
        let tokenCertificates = signedData.first { $0.tag == DERElement.context(0) }
            .flatMap(der.children)?.map(der.encoded) ?? []
        try checkAuthority(signer, certificates: tokenCertificates + outer, anchors: anchors, at: time)
        return time
    }

    /// The timestamp's own signature verifies, with a certificate issued for timestamping whose
    /// chain was trusted at `time`.
    static func checkAuthority(_ signer: SignerInfoParts, certificates: [Data], anchors: [SecCertificate]?, at time: Date) throws {
        guard let data = Authenticode.certificate(for: signer, in: certificates) else {
            throw AuthenticodeError.malformed("the timestamp's certificate isn't included")
        }
        let certificate = try Authenticode.verifySignature(certificate: data, digest: signer.digestAlgorithm,
                                                           signed: signer.signedAttributes, signature: signer.encryptedDigest)
        guard Authenticode.hasExtendedKeyUsage(certificate, OID.timeStamping) else { throw AuthenticodeError.notForCodeSigning }
        try Authenticode.evaluateTrust(certificate, with: certificates, anchors: anchors, at: time)
    }

    /// A UTCTime (YYMMDDHHMMSSZ; years 50–99 are 19xx, RFC 5280) or GeneralizedTime
    /// (YYYYMMDDHHMMSS[.fff]Z), in UTC.
    static func time(_ reader: DERReader, _ element: DERElement) -> Date? {
        guard let text = String(data: reader.value(element), encoding: .ascii), text.hasSuffix("Z") else { return nil }
        var digits = String(text.dropLast())
        if element.tag == DERElement.generalizedTime, let dot = digits.firstIndex(of: ".") {
            digits = String(digits[..<dot])
        }
        let yearDigits: Int
        switch element.tag {
        case DERElement.utcTime: yearDigits = 2
        case DERElement.generalizedTime: yearDigits = 4
        default: return nil
        }
        guard digits.count == yearDigits + 10, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        let numbers = Array(digits)
        func number(_ start: Int, _ length: Int) -> Int { Int(String(numbers[start..<(start + length)]))! }
        var year = number(0, yearDigits)
        if yearDigits == 2 { year += year >= 50 ? 1900 : 2000 }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = number(yearDigits, 2)
        components.day = number(yearDigits + 2, 2)
        components.hour = number(yearDigits + 4, 2)
        components.minute = number(yearDigits + 6, 2)
        components.second = number(yearDigits + 8, 2)
        guard components.isValidDate, let date = components.date else { return nil }
        return date
    }
}
