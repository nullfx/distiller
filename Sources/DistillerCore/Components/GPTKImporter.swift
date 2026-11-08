import Foundation

/// Imports D3DMetal from the player's own Game Porting Toolkit download.
///
/// D3DMetal is under Apple's license, so Distiller never downloads or bundles it. The player
/// downloads GPTK from developer.apple.com and points Distiller at the disk image, its mounted
/// volume, or a folder copied from it.
///
/// Layout, verified against GPTK 4.0 beta 3: the download is a bundle disk image (PDFs, sample
/// code, installers) holding a nested `Evaluation environment for Windows games <version>.dmg`.
/// Only that inner image has the `redist/lib` folder, with `external/D3DMetal.framework`,
/// `external/libd3dshared.dylib` and `wine/{x86_64-unix,x86_64-windows}/` (d3d10/11/12, d3d12core,
/// dxgi, nvapi64, nvngx-on-metalfx). That whole `lib` folder becomes the component's `lib/`,
/// which `StackComposer` merges over a Wine build's `lib/`. When `redist/lib` isn't found, the
/// importer mounts disk images at the top of what the player chose and searches those too.
public enum GPTKImporter {
    public static let licenseNotice = """
        D3DMetal is part of Apple's Game Porting Toolkit and is covered by Apple's license, \
        which you accepted when you downloaded it. Distiller copies it only into your own \
        Application Support folder and never shares or uploads it.
        """

    public static func importGPTK(from location: URL, into store: ComponentStore) async throws -> InstalledComponent {
        try store.paths.requireAvailable(.wine)
        let imported: InstalledComponent?
        if isDiskImage(location) {
            imported = try await withMountedImage(location) { volume in
                try await importSearching(volume, into: store, nestedImagesLeft: 1)
            }
        } else {
            imported = try await importSearching(location, into: store, nestedImagesLeft: 1)
        }
        guard let imported else { throw DistillerError.gptkLayoutNotRecognized(location.path) }
        return imported
    }

    /// Imports from `root`, or from a disk image at the top of `root` when `redist/lib` isn't
    /// there. Returns nil when nothing was found, so the caller can name what the player chose.
    static func importSearching(_ root: URL, into store: ComponentStore, nestedImagesLeft: Int) async throws -> InstalledComponent? {
        if let redist = findRedist(in: root) {
            return try importRedist(redist, into: store)
        }
        guard nestedImagesLeft > 0 else { return nil }
        for image in nestedImages(in: root) {
            let found = try await withMountedImage(image) { volume in
                try await importSearching(volume, into: store, nestedImagesLeft: nestedImagesLeft - 1)
            }
            if let found { return found }
        }
        return nil
    }

    /// Disk images directly inside `root`, the evaluation environment first.
    static func nestedImages(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter(isDiskImage).sorted { lhs, rhs in
            let lhsEval = lhs.lastPathComponent.localizedCaseInsensitiveContains("evaluation")
            let rhsEval = rhs.lastPathComponent.localizedCaseInsensitiveContains("evaluation")
            if lhsEval != rhsEval { return lhsEval }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    static func isDiskImage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dmg"
    }

    static func importFolder(_ root: URL, into store: ComponentStore) throws -> InstalledComponent {
        try importRedist(try locateRedist(in: root), into: store)
    }

    static func importRedist(_ redist: URL, into store: ComponentStore) throws -> InstalledComponent {
        let version = detectVersion(redist: redist)
        let manifest = ComponentManifest(
            id: "d3dmetal",
            kind: .graphics,
            version: version,
            displayName: "D3DMetal \(version)",
            arch: .x86_64,
            provides: .d3dmetal,
            placement: .wineLib,
            license: "Apple Game Porting Toolkit license (not redistributable)",
            source: "Imported from the player's Game Porting Toolkit download"
        )

        let staging = store.paths.components.appendingPathComponent(".gptk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try APFSClone.cloneItem(at: redist, to: staging.appendingPathComponent("lib", isDirectory: true))
        return try store.importDirectory(staging, manifest: manifest)
    }

    /// Finds `…/redist/lib` containing `external/D3DMetal.framework`, searching a few levels deep.
    /// Doesn't look inside disk images; `importGPTK` does that.
    public static func locateRedist(in root: URL) throws -> URL {
        guard let redist = findRedist(in: root) else {
            throw DistillerError.gptkLayoutNotRecognized(root.path)
        }
        return redist
    }

    static func findRedist(in root: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "lib",
                  url.deletingLastPathComponent().lastPathComponent == "redist" else { continue }
            if fileManager.fileExists(atPath: url.appendingPathComponent("external/D3DMetal.framework").path) {
                return url
            }
        }
        return nil
    }

    /// Reads CFBundleShortVersionString from the framework, or returns "imported".
    static func detectVersion(redist: URL) -> String {
        let framework = redist.appendingPathComponent("external/D3DMetal.framework")
        let candidates = ["Resources/Info.plist", "Versions/A/Resources/Info.plist", "Versions/Current/Resources/Info.plist"]
        for candidate in candidates {
            let url = framework.appendingPathComponent(candidate)
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let version = plist["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return "imported"
    }

    static func withMountedImage<T>(_ image: URL, _ body: (URL) async throws -> T) async throws -> T {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("distiller-gptk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let attach = try await ProcessRunner.run(
            hdiutil, arguments: ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attach.status == 0 else {
            _ = mountPoint.withUnsafeFileSystemRepresentation { rmdir($0!) }
            throw DistillerError.processFailed(command: "hdiutil attach", status: attach.status, logFile: nil)
        }
        do {
            let result = try await body(mountPoint)
            await detach(mountPoint)
            return result
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    private static func detach(_ mountPoint: URL) async {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let result = try? await ProcessRunner.run(hdiutil, arguments: ["detach", mountPoint.path])
        if result?.status != 0 {
            _ = try? await ProcessRunner.run(hdiutil, arguments: ["detach", "-force", mountPoint.path])
        }
        // rmdir, not removeItem: it only removes the folder if the image really is gone.
        _ = mountPoint.withUnsafeFileSystemRepresentation { rmdir($0!) }
    }
}
