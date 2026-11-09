import XCTest
@testable import DistillerCommunity
@testable import DistillerCore

final class SubmissionChecklistTests: XCTestCase {
    let repository = CommunityRepository(owner: "distiller-org", name: "distiller-recipes", oauthClientID: "Iv1.example")
    static let installerSHA = String(repeating: "ab", count: 32)

    func recipe(installer: Bool = true, notes: String? = "GOG version 1.2.") -> Recipe {
        var draft = RecipeDraft(source: .folder(URL(fileURLWithPath: "/Games/Real Game")), title: "Real Game")
        draft.launchProgram = "Game.exe"
        draft.notes = notes ?? ""
        draft.publicInstallerURL = installer ? "https://cdn.example-publisher.com/RealGameSetup.exe" : nil
        return draft.makeRecipe()
    }

    func game(_ recipe: Recipe, checked: Bool, captures: [String]? = nil, shared: [String]? = nil) -> Game {
        var game = Game(id: "g", title: recipe.game.title, bottleID: "g", recipe: recipe, lastPlayedAt: Date(), authored: true)
        if checked, let shareable = try? CommunityCheck.shareableRecipe(from: recipe, installerSHA256: Self.installerSHA, launchExe: "C:\\Program Files\\Real Game\\Game.exe") {
            game.communityCheck = CommunityCheckResult(
                checkedAt: Date(), recipe: shareable, sourceFingerprint: CommunityCheck.fingerprint(recipe),
                installerSHA256: Self.installerSHA, hardwareKey: "M2-Base-8gpu-16gb-macos26", wine: "wine-staging@11.21", graphics: nil,
                hasIcon: true, captures: captures, sharedCaptures: shared
            )
        }
        return game
    }

    func states(_ game: Game, isNewGame: Bool? = false, details: GameDetails? = nil, signedIn: Bool = true,
                report: Bool = true, confirmed: Bool = true) -> [SubmissionStep: SubmissionStepState] {
        let toSubmit = CommunityCheck.recipeToSubmit(for: game) ?? game.recipe
        let context = SubmissionChecklist.Context(
            isNewGame: isNewGame, details: details ?? GameDetails(from: toSubmit), isSignedIn: signedIn,
            includesReport: report, confirmed: confirmed,
            issues: SubmissionPlan.issues(for: game, recipe: toSubmit, repository: repository)
        )
        return Dictionary(uniqueKeysWithValues: SubmissionChecklist.make(for: game, context: context).map { ($0.step, $0) })
    }

    func testReadyWhenEverythingRequiredIsDone() {
        let all = states(game(recipe(), checked: true, captures: ["capture-1.jpg", "capture-2.jpg"], shared: ["capture-2.jpg"]))
        XCTAssertEqual(all.values.filter { $0.status.blocksSubmitting }.map(\.step), [])
        XCTAssertTrue(SubmissionChecklist.isReady(Array(all.values)))
        XCTAssertEqual(all[.pictures]?.summary, "1 screenshot and the icon")
        XCTAssertEqual(all[.review]?.summary, "Ready to submit")
        XCTAssertEqual(all[.installer]?.summary, "cdn.example-publisher.com")
    }

    func testTheCheckIsNeededThenOutOfDate() {
        var unchecked = states(game(recipe(), checked: false))
        XCTAssertEqual(unchecked[.check]?.status, .needed)
        XCTAssertFalse(unchecked[.review]?.status == .needed && unchecked[.review]?.summary.contains("community check") == true,
                       "The check's own error is shown on its step, not repeated in Review")
        XCTAssertFalse(SubmissionChecklist.isReady(Array(unchecked.values)))

        var changed = game(recipe(), checked: true)
        changed.recipe.prefix?.windows = "win7"
        unchecked = states(changed)
        XCTAssertEqual(unchecked[.check]?.status, .outOfDate)
        XCTAssertEqual(unchecked[.pictures]?.status, .optional, "Pictures come from a current check")
    }

    func testNoInstallerBlocksTheInstallerAndTheCheck() {
        let all = states(game(recipe(installer: false), checked: false))
        XCTAssertEqual(all[.installer]?.status, .needed)
        XCTAssertEqual(all[.check]?.summary, "Needs the installer link first")
    }

    func testANewGameNeedsItsCatalogueDetails() {
        let checked = game(recipe(), checked: true)
        let incomplete = GameDetails(slug: "real-game", title: "Real Game")
        XCTAssertEqual(states(checked, isNewGame: true, details: incomplete)[.details]?.status, .needed)
        XCTAssertEqual(states(checked, isNewGame: false, details: incomplete)[.details]?.status, .done, "Existing games keep their entry")
        XCTAssertEqual(states(checked, isNewGame: nil, details: incomplete)[.details]?.status, .done, "Unknown until signed in")
    }

    func testOptionalStepsDontBlock() {
        let all = states(game(recipe(notes: nil), checked: true), report: false)
        XCTAssertEqual(all[.details]?.status, .optional)
        XCTAssertEqual(all[.pictures]?.status, .optional)
        XCTAssertEqual(all[.pictures]?.summary, "The icon only; no screenshots", "A check from the command line captures none")
        XCTAssertEqual(all[.report]?.status, .optional)
        XCTAssertTrue(SubmissionChecklist.isReady(Array(all.values)))
    }

    func testReviewNeedsAnAccountAndConfirmations() {
        let checked = game(recipe(), checked: true)
        XCTAssertEqual(states(checked, signedIn: false)[.review]?.summary, "Sign in to GitHub")
        XCTAssertEqual(states(checked, confirmed: false)[.review]?.status, .needed)
    }
}
