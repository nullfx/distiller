import Foundation
import Yams

/// Where a component a recipe names by tag comes from, how it's verified and installed, and
/// what it provides: one reviewed file per tag (`components/<kind>/<tag>.yaml` in the
/// community repository), the same way recipes are shared. Recipes name Wine builds by tag
/// (`stack.runner.family`); a tag Distiller doesn't know can be described by the player, checked,
/// installed and submitted (`SourceInstaller`, the app's Add a Source flow).
///
/// A source is native code that runs on players' Macs, so its rules are stricter than a
/// recipe's: downloaded from its publisher only (a GitHub release), verified by the checksum
/// GitHub publishes for the file, complete (anything it needs comes from its download or from
/// another source, `librariesFrom`), its licence declared, and, when it ships D3DMetal, labelled
/// (`containsD3DMetal`) so players see it before downloading.
public struct ComponentSource: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case wine, graphics
    }

    public struct GitHubRelease: Codable, Equatable, Sendable {
        /// "owner/name".
        public var repository: String
        /// Matches the file to download; its first capture group is the version.
        public var asset: String

        public init(repository: String, asset: String) {
            self.repository = repository
            self.asset = asset
        }
    }

    public struct Get: Codable, Equatable, Sendable {
        public var githubRelease: GitHubRelease

        enum CodingKeys: String, CodingKey {
            case githubRelease = "github_release"
        }

        public init(githubRelease: GitHubRelease) {
            self.githubRelease = githubRelease
        }
    }

    public struct Provides: Codable, Equatable, Sendable {
        /// For Wine builds: the family recipes name (`stack.runner.family`), and what bottles
        /// made with it can move to.
        public var family: String?
        public var arch: CPUArch?
        /// For graphics layers.
        public var backend: GraphicsBackend?

        public init(family: String? = nil, arch: CPUArch? = nil, backend: GraphicsBackend? = nil) {
            self.family = family
            self.arch = arch
            self.backend = backend
        }
    }

    public var schema = 1
    public var tag: String
    public var kind: Kind
    public var name: String
    public var summary: String?
    public var publisher: String
    public var homepage: String
    /// SPDX expression, such as "LGPL-2.1-or-later".
    public var license: String
    public var get: Get
    public var provides: Provides
    /// Another source whose installed build supplies the libraries this one needs but doesn't
    /// ship (cloned next to its own when it's installed).
    public var librariesFrom: String?
    /// The download includes Apple's D3DMetal. Complying with Apple's terms is the
    /// publisher's responsibility; Distiller says so and asks before downloading it.
    public var containsD3DMetal: Bool?

    public var id: String { tag }

    enum CodingKeys: String, CodingKey {
        case schema, tag, kind, name, summary, publisher, homepage, license, get, provides
        case librariesFrom = "libraries_from"
        case containsD3DMetal = "contains_d3dmetal"
    }

    public init(tag: String, kind: Kind, name: String, summary: String? = nil, publisher: String, homepage: String,
                license: String, get: Get, provides: Provides, librariesFrom: String? = nil, containsD3DMetal: Bool? = nil) {
        self.tag = tag
        self.kind = kind
        self.name = name
        self.summary = summary
        self.publisher = publisher
        self.homepage = homepage
        self.license = license
        self.get = get
        self.provides = provides
        self.librariesFrom = librariesFrom
        self.containsD3DMetal = containsD3DMetal
    }

    /// The family recipes name for a Wine source (its own tag unless it says otherwise).
    public var family: String { provides.family ?? tag }

    /// Where the community repository keeps this source.
    public var repositoryPath: String { "components/\(kind.rawValue)/\(tag).yaml" }

    // MARK: Checking

    public static let tagPattern = "^[a-z0-9][a-z0-9-]{1,39}$"

    /// What's wrong with the source, in plain words (empty when it's fine).
    public var problems: [String] {
        var problems: [String] = []
        if tag.range(of: Self.tagPattern, options: .regularExpression) == nil {
            problems.append("The tag must be 2–40 lowercase letters, digits and hyphens, such as wine-staging.")
        }
        if schema != 1 { problems.append("This version of Distiller reads source schema 1.") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Give the source a name.") }
        if publisher.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Say who publishes it.") }
        if URL(string: homepage)?.scheme != "https" { problems.append("The homepage must be an https address.") }
        if license.range(of: "^[A-Za-z0-9.+-]+( (AND|OR|WITH) [A-Za-z0-9.+-]+)*$", options: .regularExpression) == nil {
            problems.append("Give the licence as an SPDX identifier, such as LGPL-2.1-or-later.")
        }
        let release = get.githubRelease
        if release.repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) == nil {
            problems.append("The repository must be owner/name, as on GitHub.")
        }
        if let regex = try? NSRegularExpression(pattern: release.asset) {
            if regex.numberOfCaptureGroups < 1 {
                problems.append("The file pattern needs a group, in parentheses, around the version.")
            }
        } else {
            problems.append("The file pattern isn't a valid regular expression.")
        }
        switch kind {
        case .wine:
            if let family = provides.family, family.range(of: Self.tagPattern, options: .regularExpression) == nil {
                problems.append("The family must look like a tag (lowercase letters, digits and hyphens).")
            }
            if provides.backend != nil { problems.append("A Wine build doesn't provide a graphics backend.") }
        case .graphics:
            if provides.backend == nil { problems.append("Say which graphics backend the layer provides.") }
        }
        if let from = librariesFrom {
            if from == tag { problems.append("A source can't take libraries from itself.") }
            if from.range(of: Self.tagPattern, options: .regularExpression) == nil {
                problems.append("Libraries must come from another source's tag.")
            }
        }
        return problems
    }

    // MARK: YAML

    public static func decode(yaml: String) throws -> ComponentSource {
        let source = try YAMLDecoder().decode(ComponentSource.self, from: yaml)
        let problems = source.problems
        guard problems.isEmpty else { throw DistillerError.invalidRecipe(problems.joined(separator: " ")) }
        return source
    }

    public func encoded() throws -> String {
        try YAMLEncoder().encode(self)
    }

    /// "^WS12WineSikarugir([0-9][0-9._]*)\.tar\.xz$" from "WS12WineSikarugir10.0_8.tar.xz": the
    /// version is the longest run of digits with separators (else the last run of digits)
    /// before the extension.
    public static func pattern(forFileName fileName: String) -> String {
        let extensions = [".tar.xz", ".tar.gz", ".tar.bz2", ".tgz", ".zip"]
        let suffix = extensions.first { fileName.lowercased().hasSuffix($0) } ?? ""
        let stem = String(fileName.dropLast(suffix.count))
        guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:[._][0-9]+)*") else { return "" }
        let matches = regex.matches(in: stem, range: NSRange(stem.startIndex..., in: stem))
        let separated = matches.filter { match in
            Range(match.range, in: stem).map { stem[$0].contains(".") || stem[$0].contains("_") } ?? false
        }
        guard let version = separated.max(by: { $0.range.length < $1.range.length }) ?? matches.last,
              let range = Range(version.range, in: stem) else {
            return "^" + NSRegularExpression.escapedPattern(for: fileName) + "$"
        }
        return "^" + NSRegularExpression.escapedPattern(for: String(stem[..<range.lowerBound]))
            + "([0-9][0-9._]*)"
            + NSRegularExpression.escapedPattern(for: String(stem[range.upperBound...]) + String(fileName.suffix(suffix.count))) + "$"
    }

    /// Which version a release file is, by `get.githubRelease.asset`; nil if it doesn't match.
    public func version(of assetName: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: get.githubRelease.asset) else { return nil }
        return EnvironmentSetup.version(in: assetName, matching: regex)
    }
}

/// The sources Distiller knows: the ones built in (what it has always installed), and the ones
/// the player added on this Mac (`DistillerPaths.sources`). A player's source with the same tag
/// as a built-in one is ignored.
public struct ComponentSources: Sendable {
    public static let builtIn: [ComponentSource] = [
        WineSource.gcenxStaging, WineSource.gcenxDevel,
    ].map { wine in
        ComponentSource(
            tag: wine.id, kind: .wine, name: wine.displayName, summary: wine.summary, publisher: "Gcenx",
            homepage: "https://github.com/\(wine.repository)", license: "LGPL-2.1-or-later",
            get: .init(githubRelease: .init(repository: wine.repository, asset: wine.assetPattern)),
            provides: .init(family: wine.family, arch: wine.arch)
        )
    } + GraphicsLayerSource.all.map { layer in
        ComponentSource(
            tag: layer.id, kind: .graphics, name: layer.displayName, publisher: layer.repository.components(separatedBy: "/")[0],
            homepage: "https://github.com/\(layer.repository)", license: layer.license,
            get: .init(githubRelease: .init(repository: layer.repository, asset: layer.assetPattern)),
            provides: .init(arch: .x86_64, backend: layer.provides)
        )
    }

    public let local: [ComponentSource]

    public var all: [ComponentSource] {
        Self.builtIn + local.filter { source in !Self.builtIn.contains { $0.tag == source.tag } }
    }

    public func source(tag: String) -> ComponentSource? {
        all.first { $0.tag == tag }
    }

    /// The Wine source recipes reach with `family`.
    public func wineSource(family: String) -> ComponentSource? {
        all.first { $0.kind == .wine && $0.family == family }
    }
}

/// A Wine build a recipe names that isn't installed, and whether a known source can install it.
public struct MissingComponent: Equatable, Sendable, Identifiable {
    public var kind: ComponentSource.Kind
    /// The family (for Wine) the recipe names.
    public var tag: String
    public var minVersion: String?
    /// A source the player added on this Mac, which can install it; nil when Distiller knows no
    /// source (the player can describe one).
    public var source: ComponentSource?

    public var id: String { "\(kind.rawValue)/\(tag)" }
}

extension DistillerEngine {
    public var componentSources: ComponentSources {
        let folder = paths.sources
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let local = files.filter { $0.pathExtension == "yaml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? ComponentSource.decode(yaml: String(contentsOf: $0, encoding: .utf8)) }
        return ComponentSources(local: local)
    }

    /// Saves a source the player described, so Distiller can install it and later updates of it.
    @discardableResult
    public func saveSource(_ source: ComponentSource) throws -> URL {
        let problems = source.problems
        guard problems.isEmpty else { throw DistillerError.invalidRecipe(problems.joined(separator: " ")) }
        guard !ComponentSources.builtIn.contains(where: { $0.tag == source.tag }) else {
            throw DistillerError.invalidRecipe("\(source.tag) is one of Distiller's own sources.")
        }
        try FileManager.default.createDirectory(at: paths.sources, withIntermediateDirectories: true)
        let url = paths.sources.appendingPathComponent("\(source.tag).yaml")
        try source.encoded().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The Wine build `recipe` names when nothing installed matches it and Distiller's own
    /// sources (which the setup assistant installs) don't provide it.
    public func missingComponents(for recipe: Recipe) -> [MissingComponent] {
        let runner = recipe.stack.runner
        guard runner.family != "any", components.wineCandidates(for: runner).isEmpty else { return [] }
        let sources = componentSources
        if ComponentSources.builtIn.contains(where: { $0.kind == .wine && $0.family == runner.family }) { return [] }
        return [MissingComponent(kind: .wine, tag: runner.family, minVersion: runner.minVersion,
                                 source: sources.wineSource(family: runner.family))]
    }
}
