import XCTest
@testable import DistillerCore

/// A pretend publisher's download servers, by URL.
final class FakeDownloads: URLProtocol {
    struct Route {
        var size: Int64 = 1_000_000
        var needsCookie = false
        var headAllowed = true
        var status = 200
        /// What a full GET returns (instead of a few placeholder bytes).
        var body: Data?
    }

    nonisolated(unsafe) static var routes: [String: Route] = [:]
    /// "METHOD url", with any cookie or referrer header the request carried.
    nonisolated(unsafe) static var requests: [String] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDownloads.self]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let extras = ["Cookie", "Referer"].filter { request.value(forHTTPHeaderField: $0) != nil }
        Self.requests.append(([method, url.absoluteString] + extras).joined(separator: " "))
        guard let route = Self.routes[url.absoluteString] else { return respond(404, [:]) }
        if route.needsCookie, request.value(forHTTPHeaderField: "Cookie") == nil { return respond(403, [:]) }
        if method == "HEAD", !route.headAllowed { return respond(405, [:]) }
        if route.status != 200 { return respond(route.status, [:]) }
        if method == "GET", request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
            return respond(206, ["Content-Range": "bytes 0-0/\(route.size)", "Content-Length": "1"], body: Data([0x4D]))
        }
        let body = route.body ?? Data(count: 16)
        respond(200, ["Content-Length": "\(route.body.map { Int64($0.count) } ?? route.size)"], body: method == "HEAD" ? Data() : body)
    }

    private func respond(_ status: Int, _ headers: [String: String], body: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class InstallerCaptureTests: XCTestCase {
    let clicked = URL(string: "https://www.example-publisher.com/download/get?os=win")!
    let redirect = URL(string: "https://downloads.example-publisher.com/client/RealGameSetup.exe")!
    let signed = URL(string: "https://cdn.example-cdn.net/a1/RealGameSetup.exe?Expires=1800000000&Signature=abc&Key-Pair-Id=K1")!

    override func setUp() {
        FakeDownloads.routes = [:]
        FakeDownloads.requests = []
    }

    func capture(_ links: [URL], size: Int64 = 1_000_000) -> CapturedDownload {
        CapturedDownload(page: URL(string: "https://www.example-publisher.com/download"), links: links, fileName: "RealGameSetup.exe", size: size)
    }

    func testPrefersTheLinkThePlayerClicked() async {
        FakeDownloads.routes = [clicked.absoluteString: .init(), redirect.absoluteString: .init()]
        let result = await InstallerLinkTest.test(capture([clicked, redirect, signed]), session: FakeDownloads.session())
        XCTAssertEqual(result.url, clicked)
        XCTAssertEqual(result.tried.count, 1, "Stops at the first that works")
    }

    func testSkipsLinksThatNeedThePageOrExpire() async {
        FakeDownloads.routes = [clicked.absoluteString: .init(needsCookie: true), redirect.absoluteString: .init(), signed.absoluteString: .init()]
        let result = await InstallerLinkTest.test(capture([clicked, redirect, signed]), session: FakeDownloads.session())
        XCTAssertEqual(result.url, redirect)
        XCTAssertEqual(result.tried.first?.outcome, .refused(status: 403))

        let onlySigned = await InstallerLinkTest.test(capture([signed]), session: FakeDownloads.session())
        XCTAssertNil(onlySigned.url)
        XCTAssertEqual(onlySigned.tried.first?.outcome, .shortLived, "Never even requested")
        XCTAssertFalse(FakeDownloads.requests.contains { $0.contains("Cookie") || $0.contains("Referer") }, "\(FakeDownloads.requests)")
    }

    func testFallsBackToAOneByteGetWhenHeadIsRefused() async {
        FakeDownloads.routes = [redirect.absoluteString: .init(headAllowed: false)]
        let result = await InstallerLinkTest.test(capture([redirect]), session: FakeDownloads.session())
        XCTAssertEqual(result.url, redirect)
        XCTAssertTrue(FakeDownloads.requests.contains("GET \(redirect.absoluteString)"))
    }

    func testRejectsADifferentFileAndPlainHTTP() async {
        FakeDownloads.routes = [redirect.absoluteString: .init(size: 42)]
        let different = await InstallerLinkTest.test(capture([redirect]), session: FakeDownloads.session())
        XCTAssertEqual(different.tried.first?.outcome, .differentFile(size: 42))
        let http = await InstallerLinkTest.test(capture([URL(string: "http://downloads.example-publisher.com/Setup.exe")!]), session: FakeDownloads.session())
        XCTAssertEqual(http.tried.first?.outcome, .notHTTPS)
    }

    func testRecognisesShortLivedLinks() {
        XCTAssertTrue(InstallerLinkTest.looksShortLived(signed))
        XCTAssertTrue(InstallerLinkTest.looksShortLived(URL(string: "https://b.example.blob.core.windows.net/x/Setup.exe?sv=2020&se=2026&sig=abc")!))
        XCTAssertTrue(InstallerLinkTest.looksShortLived(URL(string: "https://s3.amazonaws.com/b/Setup.exe?X-Amz-Expires=300&X-Amz-Signature=f")!))
        XCTAssertFalse(InstallerLinkTest.looksShortLived(clicked))
        XCTAssertFalse(InstallerLinkTest.looksShortLived(redirect))
    }

    func testCaptureDropsRepeatedLinks() {
        XCTAssertEqual(capture([clicked, clicked, redirect, clicked]).links, [clicked, redirect])
    }
}
