import Foundation
import Security

/// Checks a downloaded installer against a recipe's `sha256`, its `signer`, or both. With both,
/// either passing is enough: the checksum first (it pins the exact file), then the publisher's
/// signature (`Authenticode`, timestamp-aware), which still holds when the publisher ships a new
/// installer. Requiring both would add nothing: a matching checksum already proves it's the file
/// that was checked.
public enum InstallerCheck {
    public enum Passed: Equatable, Sendable {
        /// It's the exact file the recipe was checked with.
        case checksum
        /// Its publisher signed it. `changed`: the recipe also has a checksum, which no longer
        /// matches, so the publisher has shipped a different installer since the recipe was checked.
        case signer(changed: Bool)

        public var installerChanged: Bool { self == .signer(changed: true) }
    }

    @discardableResult
    public static func verify(_ file: URL, name: String? = nil, sha256: String?, signer: String?, anchors: [SecCertificate]? = nil) throws -> Passed {
        let name = name ?? file.lastPathComponent
        var checksumProblem: Error?
        if let sha256 {
            do {
                try Checksum.verify(file, expected: sha256)
                return .checksum
            } catch {
                checksumProblem = error
            }
        }
        if let signer {
            do {
                _ = try Authenticode.verify(file, expectedSigner: signer, anchors: anchors)
                return .signer(changed: sha256 != nil)
            } catch {
                let checksumPart = checksumProblem == nil ? "" : "It doesn't match the recipe's checksum, and "
                let reason = error.localizedDescription
                throw DistillerError.invalidRecipe("\(name) can't be trusted: \(checksumPart)\(checksumPart.isEmpty ? reason : reason.prefix(1).lowercased() + reason.dropFirst())")
            }
        }
        if let checksumProblem { throw checksumProblem }
        throw DistillerError.invalidRecipe("\(name) has nothing to be checked against.")
    }
}
