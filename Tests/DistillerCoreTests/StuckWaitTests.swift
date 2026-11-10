import XCTest
@testable import DistillerCore

/// Waits for every program in a bottle to exit that a .NET Framework background service would
/// keep going forever.
final class StuckWaitTests: XCTestCase {
    func programs(_ paths: [String]) -> [RunningWindowsProgram] {
        paths.enumerated().map { RunningWindowsProgram(pid: $0 + 32, windowsPath: $1) }
    }

    let netService = #"C:\windows\Microsoft.NET\Framework\v4.0.30319\mscorsvw.exe"#

    func testOnlyWineAndTheNETServiceLeftStopsTheService() {
        let left = programs([
            #"C:\windows\system32\services.exe"#, #"C:\windows\system32\winedevice.exe"#,
            #"C:\windows\system32\svchost.exe"#, #"C:\windows\system32\plugplay.exe"#,
            #"C:\windows\system32\rpcss.exe"#, netService, netService, #"C:\windows\system32\wmic.exe"#,
        ])
        XCTAssertEqual(StuckWait.servicesToStop(left), ["clr_optimization_v4.0.30319_32", "clr_optimization_v4.0.30319_64"])
    }

    func testAnythingElseRunningMeansTheWaitIsReal() {
        // An installer still running, including Windows' own (msiexec, ngen) and Wine's settings.
        for other in [#"C:\windows\system32\msiexec.exe"#, #"C:\windows\Microsoft.NET\Framework\v4.0.30319\ngen.exe"#,
                      #"C:\a1773ebc5edeaa438cb1\Setup.exe"#, #"C:\windows\system32\winecfg.exe"#,
                      #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#] {
            XCTAssertEqual(StuckWait.servicesToStop(programs([#"C:\windows\system32\services.exe"#, netService, other])), [], other)
        }
    }

    func testNothingToStopWithoutTheService() {
        XCTAssertEqual(StuckWait.servicesToStop(programs([#"C:\windows\system32\services.exe"#, #"C:\windows\system32\explorer.exe"#])), [])
        XCTAssertEqual(StuckWait.servicesToStop([]), [])
    }

    func testFindsWinetricksWaitingForTheServer() {
        let list = """
          100     1 /Applications/Distiller.app/Contents/MacOS/Distiller
          200   100 /bin/bash /x/winetricks -q dotnet48
          201   200 /bin/bash /x/winetricks -q dotnet48
          202   201 /x/wine-11/bin/wineserver -w
          300     1 /x/wine-11/bin/wineserver -w
          400     1 C:\\windows\\Microsoft.NET\\Framework\\v4.0.30319\\mscorsvw.exe
        """
        let processes = StuckWait.parseProcessList(list)
        XCTAssertEqual(processes.count, 6)
        XCTAssertEqual(processes[3], .init(pid: 202, parent: 201, command: "/x/wine-11/bin/wineserver -w"))
        XCTAssertTrue(StuckWait.isWaitingForServer(under: 200, in: processes))
        // Another bottle's wait (not under this winetricks) doesn't count.
        XCTAssertFalse(StuckWait.isWaitingForServer(under: 201, in: StuckWait.parseProcessList(list.replacingOccurrences(of: "202   201", with: "202     1"))))
    }

    func testTheServerItselfIsNotAWait() {
        let processes = StuckWait.parseProcessList("""
          200     1 /bin/bash /x/winetricks -q corefonts
          202   200 /x/wine-11/lib/wine/../../bin/wineserver
          203   200 /x/wine-11/bin/wine reg add HKCU\\Software\\Example /v -w
        """)
        XCTAssertFalse(StuckWait.isWaitingForServer(under: 200, in: processes))
    }
}
