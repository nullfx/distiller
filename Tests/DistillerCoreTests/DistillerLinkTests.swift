import Foundation
import XCTest
@testable import DistillerCommunity

final class DistillerLinkTests: XCTestCase {
    func link(_ text: String) -> DistillerLink? { URL(string: text).flatMap(DistillerLink.init(url:)) }

    func testParsesTheWebsiteLinks() {
        XCTAssertEqual(link("distiller://install?game=guild-wars-2&recipe=dxvk"), .install(game: "guild-wars-2", recipe: "dxvk"))
        XCTAssertEqual(link("distiller://install?recipe=dxvk&game=guild-wars-2"), .install(game: "guild-wars-2", recipe: "dxvk"))
        XCTAssertEqual(link("DISTILLER://game/guild-wars-2"), .showGame("guild-wars-2"))
    }

    func testRoundTrips() {
        for value in [DistillerLink.install(game: "real-game", recipe: "d3dmetal"), .showGame("real-game")] {
            XCTAssertEqual(DistillerLink(url: value.url), value)
        }
        XCTAssertEqual(DistillerLink.install(game: "real-game", recipe: "dxvk").url.absoluteString, "distiller://install?game=real-game&recipe=dxvk")
        XCTAssertEqual(DistillerLink.showGame("real-game").url.absoluteString, "distiller://game/real-game")
    }

    func testRejectsAnythingElse() {
        for text in [
            "https://install?game=guild-wars-2&recipe=dxvk",                 // another scheme
            "distiller://install?game=guild-wars-2",                          // no recipe
            "distiller://install?game=Guild-Wars&recipe=dxvk",                // not a slug
            "distiller://install?game=../etc&recipe=dxvk",
            "distiller://install?game=a&recipe=dxvk",                         // too short
            "distiller://install?game=x-game&recipe=dxvk&game=y-game",        // ambiguous
            "distiller://install/extra?game=x-game&recipe=dxvk",
            "distiller://install?game=x-game&recipe=https%3A%2F%2Fevil",
            "distiller://game/",
            "distiller://game/x-game/more",
            "distiller://run?exe=C:%5Cevil.exe",                              // unknown action
            "distiller://game/-starts-with-hyphen",
        ] {
            XCTAssertNil(link(text), text)
        }
    }
}
