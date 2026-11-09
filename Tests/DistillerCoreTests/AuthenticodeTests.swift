import Security
import XCTest
@testable import DistillerCore

/// Fixtures from `Fixtures/make-authenticode-fixtures.py`: a tiny program signed by a throwaway
/// test authority, which these tests trust explicitly (macOS doesn't).
final class AuthenticodeTests: XCTestCase {
    var signed: Data!
    var root: SecCertificate!

    override func setUpWithError() throws {
        signed = try Data(contentsOf: fixtureURL("authenticode-signed", "exe"))
        root = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: fixtureURL("authenticode-root", "cer")) as CFData))
    }

    func verify(_ data: Data, signer: String? = nil, date: Date = Date()) throws -> AuthenticodeSignature {
        try Authenticode.verify(data: data, expectedSigner: signer, anchors: [root], date: date)
    }

    func assertFails(_ data: Data, with expected: AuthenticodeError? = nil, signer: String? = nil, date: Date = Date(), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try verify(data, signer: signer, date: date), file: file, line: line) { error in
            guard let expected else { return }
            switch (expected, error as? AuthenticodeError) {
            case (.untrusted, .untrusted?), (.malformed, .malformed?): break
            default: XCTAssertEqual(error as? AuthenticodeError, expected, file: file, line: line)
            }
        }
    }

    func testVerifiesASignedProgram() throws {
        let signature = try verify(signed)
        XCTAssertEqual(signature, AuthenticodeSignature(signer: "Distiller Test Publisher", digestAlgorithm: "SHA-256"))
        XCTAssertNoThrow(try verify(signed, signer: "distiller test publisher"), "Names compare without case")
    }

    func testChecksTheSignerTheRecipeNames() {
        assertFails(signed, with: .wrongSigner(expected: "Example Publisher, Inc.", found: "Distiller Test Publisher"), signer: "Example Publisher, Inc.")
    }

    func testNeedsATrustedRootThatHasntExpired() {
        XCTAssertThrowsError(try Authenticode.verify(data: signed)) { error in
            guard case .untrusted? = error as? AuthenticodeError else { return XCTFail("\(error)") }
        }
        assertFails(signed, with: .untrusted(""), date: Date(timeIntervalSinceNow: 200 * 365 * 86_400))
    }

    func testNoticesAnyChangeToTheProgram() {
        var changed = signed!
        changed[0x300] ^= 0x01
        assertFails(changed, with: .contentsChanged)
    }

    func testNeedsACodeSigningCertificate() throws {
        assertFails(try Data(contentsOf: fixtureURL("authenticode-wrong-usage", "exe")), with: .notForCodeSigning)
    }

    func testUnsignedAndNonWindowsFiles() {
        var unsigned = signed!
        let directory = 0x98 + 112 + 4 * 8
        unsigned.replaceSubrange(directory..<(directory + 8), with: Data(count: 8))
        assertFails(unsigned, with: .unsigned)
        assertFails(Data("not a program".utf8), with: .notAWindowsProgram)
    }

    func testBrokenCertificateTablesAreRefused() {
        let directory = 0x98 + 112 + 4 * 8
        var beyond = signed!
        beyond.replaceSubrange((directory + 4)..<(directory + 8), with: withUnsafeBytes(of: UInt32(1_000_000).littleEndian) { Data($0) })
        assertFails(beyond, with: .malformed(""))
        var truncated = signed!
        truncated.removeLast(200)
        assertFails(truncated, with: .malformed(""))
    }

    /// Any single changed byte in what the signature protects makes verification fail,
    /// cleanly. Left out: fields PKCS #7 doesn't sign and Distiller doesn't use (the version
    /// numbers, the list of digest algorithms, the signature algorithm's label, which the
    /// key's type decides, and the digest algorithm's empty parameters), extra certificates
    /// (only the chain to a trusted root counts), the signing certificate's outer signature
    /// algorithm label (X.509 doesn't sign it; macOS parses certificates), and the padding.
    func testEveryCorruptedSignatureByteFails() throws {
        let directory = 0x98 + 112 + 4 * 8
        let table = Int(signed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: directory, as: UInt32.self) })
        let length = Int(signed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: table, as: UInt32.self) })
        let blobStart = table + 8
        let der = DERReader(signed.subdata(in: blobStart..<(table + length)))
        let rootData = try Data(contentsOf: fixtureURL("authenticode-root", "cer"))

        let contentInfo = try XCTUnwrap(der.element(at: 0).flatMap(der.children))
        let signedData = try XCTUnwrap(der.children(of: contentInfo[1]).flatMap { $0.first }.flatMap(der.children))
        let certificates = try XCTUnwrap(signedData.first { $0.tag == DERElement.context(0) }.flatMap(der.children))
        let signerInfo = try XCTUnwrap(der.children(of: signedData.last!)?.first.flatMap(der.children))
        var ignored: [Range<Int>] = [signedData[0].encoded, signedData[1].encoded, signerInfo[0].encoded, signerInfo[4].encoded]
        ignored += certificates.filter { der.encoded($0) == rootData }.map(\.encoded)
        for certificate in certificates where der.encoded(certificate) != rootData {
            if let outerAlgorithm = der.children(of: certificate)?.dropFirst().first { ignored.append(outerAlgorithm.encoded) }
        }
        if let parameters = der.children(of: signerInfo[2])?.dropFirst().first { ignored.append(parameters.encoded) }
        let signatureEnd = contentInfo.last!.encoded.upperBound

        var checked = 0
        for offset in (blobStart..<signed.count) where !ignored.contains(where: { $0.contains(offset - blobStart) }) {
            guard offset - blobStart < signatureEnd else { break }
            var corrupted = signed!
            corrupted[offset] ^= 0xFF
            XCTAssertThrowsError(try verify(corrupted), "Byte \(offset) changed without failing")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1200, "Most of the signature is protected")
    }
}
