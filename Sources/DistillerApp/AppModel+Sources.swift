import Foundation
import Observation
import DistillerCommunity
import DistillerCore

/// A recipe names a Wine build Distiller doesn't have and has no source for (or has a source
/// the player added but hasn't installed): the player describes where it comes from, Distiller
/// downloads, checks and installs it, and the player can submit the source so others get it.
@MainActor
@Observable
final class MissingSourceSession: Identifiable {
    let id = UUID()
    let recipeTitle: String
    let missing: MissingComponent
    private let engine: DistillerEngine
    private let submitter: RecipeSubmitter?
    private let finish: (Bool) -> Void

    // The source, as the player describes it.
    var name = ""
    var publisher = ""
    var homepage = ""
    var license = "LGPL-2.1-or-later"
    var repository = ""
    var assetPattern = ""
    var librariesFrom: String?
    var summary = ""

    private(set) var files: [ReleaseFile] = []
    var selectedFileID: ReleaseFile.ID?
    private(set) var isFinding = false
    private(set) var isWorking = false
    private(set) var progress: String?
    private(set) var error: String?
    private(set) var result: SourceInstallResult?
    private(set) var pullRequest: URL?
    /// Wine builds whose libraries can complete this one.
    let libraryDonors: [String]

    init(recipeTitle: String, missing: MissingComponent, engine: DistillerEngine, submitter: RecipeSubmitter?,
         finish: @escaping (Bool) -> Void) {
        self.recipeTitle = recipeTitle
        self.missing = missing
        self.engine = engine
        self.submitter = submitter
        self.finish = finish
        let donors = engine.components.installed()
            .filter { $0.manifest.kind == .wine && $0.manifest.composedFrom == nil && $0.manifest.id != missing.tag }
            .map(\.manifest.id)
        libraryDonors = Array(Set(donors + WineSource.all.map(\.id))).sorted()
        if let known = missing.source {
            name = known.name
            publisher = known.publisher
            homepage = known.homepage
            license = known.license
            repository = known.get.githubRelease.repository
            assetPattern = known.get.githubRelease.asset
            librariesFrom = known.librariesFrom
            summary = known.summary ?? ""
        }
    }

    var canSubmit: Bool { submitter != nil }
    var selectedFile: ReleaseFile? { files.first { $0.id == selectedFileID } }

    /// The source described so far.
    var source: ComponentSource {
        let trimmedRepository = repository.trimmingCharacters(in: .whitespaces)
        return ComponentSource(
            tag: missing.tag, kind: missing.kind,
            name: name.trimmingCharacters(in: .whitespaces),
            summary: summary.trimmingCharacters(in: .whitespaces).isEmpty ? nil : summary.trimmingCharacters(in: .whitespaces),
            publisher: publisher.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(trimmedRepository.split(separator: "/").first ?? "") : publisher.trimmingCharacters(in: .whitespaces),
            homepage: homepage.trimmingCharacters(in: .whitespaces).isEmpty
                ? "https://github.com/\(trimmedRepository)" : homepage.trimmingCharacters(in: .whitespaces),
            license: license.trimmingCharacters(in: .whitespaces),
            get: .init(githubRelease: .init(repository: trimmedRepository, asset: assetPattern)),
            provides: .init(family: missing.tag, arch: .x86_64),
            librariesFrom: librariesFrom,
            containsD3DMetal: result?.containsD3DMetal == true ? true : nil
        )
    }

    var problems: [String] { source.problems }

    /// Files in the source's releases that its pattern matches.
    var matchingFiles: [ReleaseFile] {
        files.filter { source.version(of: $0.name) != nil }
    }

    func findFiles() {
        isFinding = true
        error = nil
        let repository = source.get.githubRelease.repository
        Task {
            defer { isFinding = false }
            do {
                files = try await EnvironmentSetup(engine: engine).releaseFiles(repository: repository)
                if files.isEmpty { error = "github.com/\(repository) has no releases with files." }
                if !assetPattern.isEmpty, let newest = newestMatching() { selectedFileID = newest.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Choosing a file sets the pattern from its name (its version as the changing part).
    func choose(_ file: ReleaseFile) {
        selectedFileID = file.id
        if source.version(of: file.name) == nil { assetPattern = ComponentSource.pattern(forFileName: file.name) }
    }

    func newestMatching() -> ReleaseFile? {
        matchingFiles.max { VersionNumber(source.version(of: $0.name) ?? "") < VersionNumber(source.version(of: $1.name) ?? "") }
    }

    func install() {
        let source = self.source
        let file = selectedFile
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false; progress = nil }
            do {
                let setup = EnvironmentSetup(engine: engine)
                let result = try await setup.install(source, file: file) { message in
                    Task { @MainActor in self.progress = message }
                }
                self.result = result
                try engine.saveSource(self.source)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func submit() {
        guard let submitter, let result else { return }
        let notes = SourceCheckNotes(
            file: result.file.name, sha256: result.file.sha256 ?? "", librariesFrom: result.librariesFrom,
            librariesAdded: result.librariesAdded, containsD3DMetal: result.containsD3DMetal,
            exportsMacDriverFunctions: result.exportsMacDriverFunctions, recipe: recipeTitle
        )
        let source = self.source
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false; progress = nil }
            do {
                pullRequest = try await submitter.submitSource(source, notes: notes) { message in
                    Task { @MainActor in self.progress = message }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var finished = false

    func done(_ installed: Bool) {
        guard !finished else { return }
        finished = true
        finish(installed)
    }
}

extension AppModel {
    /// Before installing a recipe: for each Wine build it names that Distiller doesn't have,
    /// asks the player to describe (or install) its source. False if they cancelled.
    func resolveMissingComponents(for recipe: Recipe) async -> Bool {
        guard let engine else { return false }
        for missing in engine.missingComponents(for: recipe) {
            let submitter = tokenStore.load().map { RecipeSubmitter(repository: repository, token: $0) }
            let installed = await withCheckedContinuation { continuation in
                missingSource = MissingSourceSession(recipeTitle: recipe.game.title, missing: missing, engine: engine,
                                                     submitter: submitter) { installed in
                    continuation.resume(returning: installed)
                }
            }
            missingSource = nil
            reload()
            guard installed else { return false }
        }
        return true
    }
}
