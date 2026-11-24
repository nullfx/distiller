import Foundation
import XCTest
@testable import DistillerCore

/// ⌘ as Ctrl (and Option as Alt) in Windows programs: written into the bottle's user.reg, which
/// Wine's macOS driver reads when it starts.
final class KeyboardSettingsTests: XCTestCase {
    let header = """
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Software\\\\Wine\\\\Debug] 1795558146
    #time=1dd7c606c647da0
    "RelayFromExclude"="winex11.drv;winemac.drv"

    [Software\\\\Wine\\\\DllOverrides] 1795558133
    #time=1dd7c6064ad3854

    """
    let key = #"Software\Wine\Mac Driver"#
    let now = Date(timeIntervalSince1970: 1_795_560_000)

    func testAddsTheKeyWhenItIsMissing() {
        let result = UserRegistryFile.setting([("LeftCommandIsCtrl", "y"), ("RightCommandIsCtrl", "y")], key: key, in: header, now: now)
        XCTAssertTrue(result.hasPrefix(header), "Nothing else changes")
        XCTAssertTrue(result.hasSuffix(#"""
        [Software\\Wine\\Mac Driver] 1795560000
        #time=1dd7c64bcf92000
        "LeftCommandIsCtrl"="y"
        "RightCommandIsCtrl"="y"

        """#), result)
        XCTAssertEqual(UserRegistryFile.setting([("LeftCommandIsCtrl", "y"), ("RightCommandIsCtrl", "y")], key: key, in: result, now: now), result,
                       "Setting the same values again changes nothing")
    }

    func testUpdatesAndAddsValuesInAnExistingKey() {
        let existing = header + #"""
        [Software\\Wine\\Mac Driver] 1795558000
        #time=1dd7c6064ad3854
        "LeftCommandIsCtrl"="n"
        "RetinaMode"="y"

        [Software\\Wine\\X11 Driver] 1795558000

        """#
        let result = UserRegistryFile.setting([("LeftCommandIsCtrl", "y"), ("LeftOptionIsAlt", "n")], key: key, in: existing, now: now)
        XCTAssertTrue(result.contains(#"""
        [Software\\Wine\\Mac Driver] 1795558000
        #time=1dd7c6064ad3854
        "LeftCommandIsCtrl"="y"
        "RetinaMode"="y"
        "LeftOptionIsAlt"="n"

        [Software\\Wine\\X11 Driver] 1795558000
        """#), result)
        XCTAssertEqual(result.components(separatedBy: "Mac Driver]").count, 2, "One key, not a second")
    }

    func testWritesTheFileOnlyWhenItExistsAndChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-keyboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("user.reg")
        XCTAssertFalse(try UserRegistryFile.set([("LeftCommandIsCtrl", "y")], key: key, in: file), "No bottle registry yet")
        try header.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try UserRegistryFile.set([("LeftCommandIsCtrl", "y")], key: key, in: file))
        XCTAssertFalse(try UserRegistryFile.set([("LeftCommandIsCtrl", "y")], key: key, in: file))

        // The engine writes the player's settings: ⌘ as Ctrl unless turned off, Option as Alt only when on.
        let engine = try DistillerEngine(paths: DistillerPaths(root: root.appendingPathComponent("home"), storage: StorageSettings()), hardware: Macs.m3Pro)
        try header.write(to: file, atomically: true, encoding: .utf8)
        engine.applyKeyboardSettings(to: root)
        var text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(#""LeftCommandIsCtrl"="y""#) && text.contains(#""RightCommandIsCtrl"="y""#))
        XCTAssertTrue(text.contains(#""LeftOptionIsAlt"="n""#))
        var settings = StorageSettings.load(fromSupportFolder: engine.paths.root)
        settings.commandAsCtrl = false
        settings.optionAsAlt = true
        try settings.save(toSupportFolder: engine.paths.root)
        engine.applyKeyboardSettings(to: root)
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(#""LeftCommandIsCtrl"="n""#) && text.contains(#""RightOptionIsAlt"="y""#))
    }
}
