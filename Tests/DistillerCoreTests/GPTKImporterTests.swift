import Foundation
import XCTest
@testable import DistillerCore

/// Builds disk images shaped like the real Game Porting Toolkit download (verified against
/// GPTK 4.0 beta 3): an outer bundle image whose D3DMetal files are only inside a nested
/// "Evaluation environment" image. No Apple files are involved: the images hold placeholder files
/// in the same layout. Creating and mounting images with hdiutil takes about 45 s.
final class GPTKImporterTests: XCTestCase {
    private var work: URL!
    private var store: ComponentStore!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("distiller-gptk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store = ComponentStore(paths: DistillerPaths(root: work.appendingPathComponent("home")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func testImportsFromNestedEvaluationImage() async throws {
        let outer = try makeBundleImage(withEvaluationImage: true)

        let component = try await GPTKImporter.importGPTK(from: outer, into: store)

        XCTAssertEqual(component.manifest.id, "d3dmetal")
        XCTAssertEqual(component.manifest.version, "9.9b1")
        let lib = component.directory.appendingPathComponent("lib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("external/libd3dshared.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("wine/x86_64-windows/d3d11.dll").path))
        let current = lib.appendingPathComponent("external/D3DMetal.framework/Versions/Current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), "A")
        try assertNoImagesLeftMounted()
    }

    func testImportsFromFolderHoldingEvaluationImage() async throws {
        // The player mounted the outer image in Finder (or copied it) and chose the folder.
        let folder = try makeBundleFolder(withEvaluationImage: true)

        let component = try await GPTKImporter.importGPTK(from: folder, into: store)

        XCTAssertEqual(component.manifest.version, "9.9b1")
        try assertNoImagesLeftMounted()
    }

    func testErrorNamesWhatThePlayerChose() async throws {
        let outer = try makeBundleImage(withEvaluationImage: false)

        do {
            _ = try await GPTKImporter.importGPTK(from: outer, into: store)
            XCTFail("Expected the import to fail")
        } catch DistillerError.gptkLayoutNotRecognized(let path) {
            XCTAssertEqual(path, outer.path)
        }
        try assertNoImagesLeftMounted()
    }

    // MARK: - Fixtures

    private func makeBundleImage(withEvaluationImage: Bool) throws -> URL {
        let folder = try makeBundleFolder(withEvaluationImage: withEvaluationImage)
        return try makeImage(from: folder, named: "Game_Porting_Toolkit_9.9_beta_1")
    }

    private func makeBundleFolder(withEvaluationImage: Bool) throws -> URL {
        let folder = work.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("metal-cpp"), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: folder.appendingPathComponent("Building your game.pdf"))
        if withEvaluationImage {
            let evaluation = try makeEvaluationFolder()
            let image = try makeImage(from: evaluation, named: "Evaluation environment for Windows games 9.9 beta 1")
            try FileManager.default.moveItem(at: image, to: folder.appendingPathComponent(image.lastPathComponent))
        }
        return folder
    }

    private func makeEvaluationFolder() throws -> URL {
        let fileManager = FileManager.default
        let root = work.appendingPathComponent("evaluation", isDirectory: true)
        let lib = root.appendingPathComponent("redist/lib", isDirectory: true)
        let framework = lib.appendingPathComponent("external/D3DMetal.framework", isDirectory: true)
        let resources = framework.appendingPathComponent("Versions/A/Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.9b1"], format: .xml, options: 0
        )
        try plist.write(to: resources.appendingPathComponent("Info.plist"))
        try Data("binary".utf8).write(to: framework.appendingPathComponent("Versions/A/D3DMetal"))
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("D3DMetal").path, withDestinationPath: "Versions/Current/D3DMetal")
        try Data("dylib".utf8).write(to: lib.appendingPathComponent("external/libd3dshared.dylib"))
        let windows = lib.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        try fileManager.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: windows.appendingPathComponent("d3d11.dll"))
        try Data("license".utf8).write(to: root.appendingPathComponent("License.rtf"))
        return root
    }

    private func makeImage(from folder: URL, named name: String) throws -> URL {
        let image = work.appendingPathComponent("\(name).dmg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-srcfolder", folder.path, "-volname", name, "-format", "UDRO", "-ov", image.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hdiutil create failed for \(name)")
        return image
    }

    private func assertNoImagesLeftMounted() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        process.standardOutput = pipe
        try process.run()
        let info = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertFalse(info.contains(work.path), "A test disk image is still mounted")
    }
}
