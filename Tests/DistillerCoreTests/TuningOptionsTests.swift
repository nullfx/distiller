import Foundation
import XCTest
@testable import DistillerCore

final class TuningOptionsTests: XCTestCase {
    private func option(_ id: String) throws -> TuningOption {
        try XCTUnwrap(TuningOptions.all.first { $0.id == id })
    }

    func testEveryOptionIsAllowedInRecipes() {
        for option in TuningOptions.all {
            XCTAssertTrue(RecipePolicy.isAllowedEnvKey(option.envKey), option.envKey)
            XCTAssertFalse(option.layers.isEmpty, option.id)
            XCTAssertFalse(option.layers.contains(.wined3d), "\(option.id): WineD3D has no curated options yet")
        }
        XCTAssertEqual(Set(TuningOptions.all.map(\.id)).count, TuningOptions.all.count, "IDs are unique")
    }

    func testOptionsFollowTheLayer() {
        XCTAssertEqual(TuningOptions.options(for: .dxvk).map(\.id), ["dxvk-async", "dxvk-frame-rate", "dxvk-hud", "metal-hud"])
        XCTAssertEqual(TuningOptions.options(for: .dxmt).map(\.id), ["dxmt-metalfx", "dxmt-frame-pacing", "metal-hud"])
        XCTAssertEqual(TuningOptions.options(for: .d3dmetal).map(\.id), ["metal-hud"])
        XCTAssertTrue(TuningOptions.options(for: .wined3d).isEmpty)
    }

    func testBuilderTurnsOnAsyncForDXVKOnly() {
        XCTAssertEqual(TuningOptions.builderDefaults(for: .dxvk), ["DXVK_ASYNC": "1"])
        XCTAssertTrue(TuningOptions.builderDefaults(for: .d3dmetal).isEmpty)
        XCTAssertTrue(TuningOptions.builderDefaults(for: .dxmt).isEmpty)
    }

    func testTogglesAndChoices() throws {
        let async = try option("dxvk-async")
        var env = TuningOptions.setting(async, to: "1", in: ["OTHER": "x"])
        XCTAssertTrue(TuningOptions.isOn(async, in: env))
        env = TuningOptions.setting(async, to: nil, in: env)
        XCTAssertEqual(env, ["OTHER": "x"])

        let hud = try option("dxvk-hud")
        env = TuningOptions.setting(hud, to: "fps,frametimes", in: env)
        XCTAssertEqual(TuningOptions.value(of: hud, in: env), "fps,frametimes")
    }

    func testDXMTConfigEntriesAreEditedOneAtATime() throws {
        let pacing = try option("dxmt-frame-pacing")
        let start = ["DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=1.5;"]
        var env = TuningOptions.setting(pacing, to: "60", in: start)
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=60;")
        XCTAssertEqual(TuningOptions.value(of: pacing, in: env), "60")

        env = TuningOptions.setting(pacing, to: "30", in: env)
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5;d3d11.preferredMaxFrameRate=30;")

        env = TuningOptions.setting(pacing, to: nil, in: env)
        XCTAssertEqual(env["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5;", "Other entries stay")
        XCTAssertNil(TuningOptions.setting(pacing, to: nil, in: ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;"])["DXMT_CONFIG"])
    }

    func testEnvironmentTextKeepsCommentsAndOtherLines() {
        let text = "# tuned for my M3\nWINEMSYNC_QLIMIT=50\nDXVK_HUD=fps"
        XCTAssertEqual(TuningOptions.settingEnvironmentLine("DXVK_ASYNC", to: "1", in: text),
                       "# tuned for my M3\nWINEMSYNC_QLIMIT=50\nDXVK_HUD=fps\nDXVK_ASYNC=1")
        XCTAssertEqual(TuningOptions.settingEnvironmentLine("DXVK_HUD", to: "fps,gpuload", in: text),
                       "# tuned for my M3\nWINEMSYNC_QLIMIT=50\nDXVK_HUD=fps,gpuload")
        XCTAssertEqual(TuningOptions.settingEnvironmentLine("DXVK_HUD", to: nil, in: text),
                       "# tuned for my M3\nWINEMSYNC_QLIMIT=50")
        XCTAssertEqual(TuningOptions.settingEnvironmentLine("DXVK_ASYNC", to: "1", in: ""), "DXVK_ASYNC=1")
        XCTAssertEqual(TuningOptions.settingEnvironmentLine("DXVK_ASYNC", to: nil, in: "# DXVK_ASYNC=1"), "# DXVK_ASYNC=1",
                       "A commented-out line is left alone")
    }
}
