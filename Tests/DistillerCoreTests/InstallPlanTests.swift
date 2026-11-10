import XCTest
@testable import DistillerCore

/// The steps an install shows the player, in the order the engine reports them.
final class InstallPlanTests: XCTestCase {
    func battleNetLike() throws -> ResolvedRecipe {
        var recipe = try loadFixtureRecipe("d3dmetal")
        recipe.schema = 2
        recipe.prefix = PrefixSpec(windows: "win10", winetricks: ["corefonts", "dotnet48", "vcrun2015"])
        recipe.install = [
            .userDownload(.init(id: "installer", prompt: "Download it.", page: "https://www.example-publisher.com/download",
                                signer: "Example Publisher, Inc.", to: "cache/Example-Setup.exe")),
            .runWindows(.init(path: "cache/Example-Setup.exe", args: nil, wait: true)),
        ]
        return RecipeResolver.resolve(recipe, for: Macs.m3Pro)
    }

    func testListsEveryStepInOrder() throws {
        let resolved = try battleNetLike()
        let tasks = InstallPlan.tasks(for: resolved)
        XCTAssertEqual(tasks.map(\.title), [
            "Creating a bottle",
            "Setting Windows to Windows 10",
            "Applying registry settings",
            "Adding \(resolved.graphics.displayName)",
            "Installing Microsoft core fonts",
            "Installing .NET Framework 4.8",
            "Installing the Visual C++ 2015 runtime",
            "Checking the installer you downloaded (Example-Setup.exe)",
            "Running Example-Setup.exe",
        ])
        XCTAssertEqual(tasks.map(\.id), Array(1...9))
        XCTAssertEqual(tasks.count, 1 + RecipeInstaller.configureStepCount(for: resolved) + resolved.install.count,
                       "The engine reports one step for the bottle, then the prefix's, then the recipe's")
    }

    func testSlowAndInteractiveStepsSaySo() throws {
        let tasks = InstallPlan.tasks(for: try battleNetLike())
        XCTAssertEqual(tasks[5].note, InstallPlan.slowNote, ".NET Framework can take half an hour or more")
        XCTAssertNil(tasks[6].note)
        XCTAssertNotNil(tasks[8].note, "Running an installer may need the player")
        XCTAssertNil(InstallPlan.step(.runWindows(.init(path: "cache/tool.exe", args: nil, wait: false))).note)
    }

    func testNamesMSIPackagesAndUnknownComponents() {
        let msi = InstallPlan.step(.runWindows(.init(path: "C:\\windows\\system32\\msiexec.exe", args: ["/i", "C:\\Installers\\Game.msi"], wait: true)))
        XCTAssertEqual(msi.title, "Running Game.msi")
        XCTAssertEqual(InstallPlan.component("vcrun2022").title, "Installing the Visual C++ 2022 runtime")
        XCTAssertEqual(InstallPlan.component("something-new").title, "Installing something-new")
        XCTAssertEqual(InstallPlan.windowsName("winxp64"), "Windows XP (64-bit)")
    }

    func testCancellingStopsTheRunningStepOnce() throws {
        let cancellation = InstallCancellation()
        let stops = Counter()
        cancellation.onCancel { stops.add() }
        XCTAssertNoThrow(try cancellation.check())
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertEqual(stops.value, 1)
        XCTAssertThrowsError(try cancellation.check()) { XCTAssertTrue($0 is CancellationError) }

        // Cancelled before the bottle existed: the stop runs as soon as there's something to stop.
        let early = InstallCancellation()
        early.cancel()
        let late = Counter()
        early.onCancel { late.add() }
        XCTAssertEqual(late.value, 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
