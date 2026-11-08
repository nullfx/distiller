import Foundation

/// Builds the Wine build a game actually runs with.
///
/// Graphics layers placed in `wine_lib` (D3DMetal, DXMT) must sit inside the Wine build's
/// own `lib/` folder. Rather than modify the shared Wine component, the composer clones it
/// (copy-on-write, so nearly free) and merges the layer's files into the clone. Results are
/// cached in `Components/_composed/`.
public enum StackComposer {
    public static func compose(
        wine: InstalledComponent,
        graphics: InstalledComponent?,
        store: ComponentStore
    ) throws -> InstalledComponent {
        guard let graphics, graphics.manifest.placement == .wineLib else { return wine }

        let key = "\(wine.manifest.id)-\(wine.manifest.version)+\(graphics.manifest.id)-\(graphics.manifest.version)"
        let destination = store.paths.composedComponents.appendingPathComponent(key, isDirectory: true)
        if let manifest = try? store.readManifest(in: destination) {
            return InstalledComponent(manifest: manifest, directory: destination)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: store.paths.composedComponents, withIntermediateDirectories: true)
        let staging = store.paths.composedComponents.appendingPathComponent(".\(key).partial", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }

        try APFSClone.cloneItem(at: wine.directory, to: staging)
        try overlay(
            graphics.directory.appendingPathComponent("lib", isDirectory: true),
            onto: staging.appendingPathComponent("lib", isDirectory: true)
        )

        var manifest = wine.manifest
        manifest.id = "\(wine.manifest.id)+\(graphics.manifest.id)"
        manifest.displayName = "\(wine.manifest.displayName) + \(graphics.manifest.displayName)"
        manifest.composedFrom = [wine.id, graphics.id]
        try store.writeManifest(manifest, in: staging)
        try fileManager.moveItem(at: staging, to: destination)
        return InstalledComponent(manifest: manifest, directory: destination)
    }

    /// Merges every file and symlink under `source` into `target`, replacing what's there.
    static func overlay(_ source: URL, onto target: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: keys) else { return }

        let sourceDepth = source.standardizedFileURL.pathComponents.count
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            let isRealDirectory = values.isDirectory == true && values.isSymbolicLink != true
            let relative = item.standardizedFileURL.pathComponents.dropFirst(sourceDepth)
            let destination = relative.reduce(target) { $0.appendingPathComponent($1) }
            if isRealDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try APFSClone.replaceItem(at: destination, withCloneOf: item)
            }
        }
    }
}

/// Copies DXVK-style DLLs into a prefix: `system32/` for 64-bit, `syswow64/` for 32-bit.
public enum GraphicsPlacer {
    public static func installPrefixDLLs(_ graphics: InstalledComponent, prefix: URL) throws {
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        if graphics.manifest.placement == .wineLib {
            // DXMT's winemetal.dll, for example: merged into Wine's lib *and* needed in the bottle.
            for name in graphics.manifest.dllsAlsoInPrefix {
                for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
                    let source = graphics.directory.appendingPathComponent("lib/wine/\(arch)/\(name)")
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let target = windows.appendingPathComponent(folder, isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    try APFSClone.replaceItem(at: target.appendingPathComponent(name), withCloneOf: source)
                }
            }
            return
        }
        guard graphics.manifest.placement == .prefixDLLs else { return }
        for folder in ["system32", "syswow64"] {
            let source = graphics.directory.appendingPathComponent(folder, isDirectory: true)
            let target = windows.appendingPathComponent(folder, isDirectory: true)
            guard let dlls = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { continue }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for dll in dlls where dll.pathExtension.lowercased() == "dll" {
                try APFSClone.replaceItem(at: target.appendingPathComponent(dll.lastPathComponent), withCloneOf: dll)
            }
        }
    }
}
