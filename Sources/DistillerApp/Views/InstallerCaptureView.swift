import AppKit
import SwiftUI
import WebKit
import DistillerCore

/// Gets a game's installer from its publisher's download page: the player browses to the page
/// and clicks the download, as they would in a browser. Distiller notes the page, the link they
/// clicked, every redirect and the final address, then tests which link a later player's
/// Distiller can download directly (`InstallerLinkTest`) and offers it for the recipe.
///
/// The browser keeps nothing (a non-persistent website data store: no cookies, cache or
/// history survive), opens only https pages, and never fills in or reads anything on them.
struct InstallerCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var capture: InstallerCaptureModel
    /// The installer's direct link and the page it came from; no link when none works on its
    /// own and the player chose to have players download it from the page.
    let onUse: (URL?, URL?) -> Void

    init(startPage: URL?, onUse: @escaping (URL?, URL?) -> Void) {
        _capture = State(initialValue: InstallerCaptureModel(startPage: startPage))
        self.onUse = onUse
    }

    var body: some View {
        VStack(spacing: 0) {
            BrowserAddressBar(capture: capture)
            Divider()
            WebViewHost(capture: capture)
                .frame(minHeight: 360)
            Divider()
            statusPanel
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 640, idealHeight: 720)
        .onDisappear { capture.discardDownload() }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch capture.state {
            case .browsing:
                Text("Go to the game's download page on the publisher's website and click its download button for Windows. Distiller saves the installer and works out a link players can download it from directly.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .downloading(let name, let fraction):
                HStack {
                    Text("Downloading \(name)…")
                    ProgressView(value: fraction).frame(maxWidth: 240)
                }
            case .testing(let name):
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloaded \(name). Checking which link works without the page…")
                }
            case .result(let download, let result):
                resultView(download, result)
            case .checking, .obtained, .rejected:
                EmptyView()
            }
            if let message = capture.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Private browsing: nothing is kept after you close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if case .result(let download, let result) = capture.state, result.url == nil, let page = download.page {
                    Button("Use the Download Page") {
                        onUse(nil, page)
                        dismiss()
                    }
                    .help("Players download the installer from this page themselves, in Distiller's browser, and Distiller checks it's the same installer.")
                }
                Button("Use This Installer") {
                    if case .result(let download, let result) = capture.state, let url = result.url {
                        onUse(url, download.page)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capture.directLink == nil)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func resultView(_ download: CapturedDownload, _ result: InstallerLinkResult) -> some View {
        if let url = result.url {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(download.fileName) (\(ByteCountFormatter.string(fromByteCount: download.size, countStyle: .file))) can be downloaded directly from:")
                    Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label(download.page == nil
                  ? "None of this download's links work without the page (they need its cookies, or they expire)."
                  : "None of this download's links work without the page (they need its cookies, or they expire). Use the download page instead: players download the installer there themselves, in Distiller's browser, and Distiller checks it's the same installer (by its checksum, or by its publisher's signature if it changes with updates).", systemImage: "xmark.octagon")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        DisclosureGroup("Links tried (\(result.tried.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(result.tried.enumerated()), id: \.offset) { _, attempt in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.describe(attempt.outcome)).frame(width: 190, alignment: .leading)
                        Text(attempt.url.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
        }
    }

    static func describe(_ outcome: InstallerLinkOutcome) -> String {
        switch outcome {
        case .works: return "Works on its own"
        case .shortLived: return "Expires (signed link)"
        case .notHTTPS: return "Not https"
        case .refused(let status): return "Needs the page (\(status))"
        case .differentFile: return "A different file"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

/// The browser's state, and its navigation and download delegate.
@MainActor
@Observable
final class InstallerCaptureModel: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    enum State {
        case browsing
        case downloading(String, Double)
        /// Finding a link that works on its own (the workshop).
        case testing(String)
        case result(CapturedDownload, InstallerLinkResult)
        /// Checking a file the player downloaded for an install or a community check.
        case checking(String)
        case obtained(URL)
        case rejected(String, String)
    }

    /// Set when the player downloads a file to install (`PageDownloadWindow`) rather than to
    /// find its link: each download is checked with this, instead of testing its links.
    @ObservationIgnored var verify: (@Sendable (URL) throws -> Void)?

    var address: String
    var state: State = .browsing
    var message: String?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored let webView: WKWebView

    /// For the download in progress: the page it started on, its links, and its file.
    @ObservationIgnored private var pageAtDownload: URL?
    @ObservationIgnored private var links: [URL] = []
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var progress: NSKeyValueObservation?

    var directLink: URL? {
        if case .result(_, let result) = state { return result.url }
        return nil
    }

    init(startPage: URL?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        address = startPage?.absoluteString ?? ""
        super.init()
        webView.navigationDelegate = self
        if let startPage { open(startPage.absoluteString) }
    }

    func open(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            message = "Enter the download page's address, starting with https://."
            return
        }
        message = nil
        webView.load(URLRequest(url: url))
    }

    func discardDownload() {
        if let destination { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        destination = nil
    }

    /// Hands over the checked file: it's kept when the window closes, and its folder is the
    /// caller's to remove (`PageDownloadWindow.removeDownload`).
    func takeObtainedFile() -> URL? {
        guard case .obtained(let file) = state else { return nil }
        destination = nil
        return file
    }

    private func refreshNavigation() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url { address = url.absoluteString }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        guard scheme == "https" else {
            if action.targetFrame?.isMainFrame ?? true {
                message = "Distiller's browser only opens secure (https) pages, so it didn't open \(url.host ?? url.absoluteString)."
            }
            return .cancel
        }
        if action.shouldPerformDownload { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !response.canShowMIMEType || disposition.hasPrefix("attachment") { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        start(download, firstLink: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        start(download, firstLink: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refreshNavigation() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refreshNavigation() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refreshNavigation() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshNavigation()
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }

    // MARK: Downloads

    private func start(_ download: WKDownload, firstLink: URL?) {
        discardDownload()
        download.delegate = self
        pageAtDownload = webView.url
        links = [firstLink, download.originalRequest?.url].compactMap { $0 }
        message = nil
        state = .downloading("the installer", 0)
        progress = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, case .downloading(let name, _) = self.state else { return }
                self.state = .downloading(name, fraction)
            }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> WKDownload.RedirectPolicy {
        if let url = request.url { links.append(url) }
        return .allow
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if let url = response.url { links.append(url) }
        let lower = suggestedFilename.lowercased()
        guard lower.hasSuffix(".exe") || lower.hasSuffix(".msi") else {
            message = "\(suggestedFilename) isn't a Windows installer (.exe or .msi). Look for the download for Windows."
            state = .browsing
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("distiller-installer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(suggestedFilename)
        destination = file
        state = .downloading(suggestedFilename, 0)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        progress = nil
        guard let file = destination else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let captured = CapturedDownload(page: pageAtDownload, links: links, fileName: file.lastPathComponent, size: size, localFile: file)
        if let verify {
            state = .checking(file.lastPathComponent)
            Task {
                do {
                    try await Task.detached { try verify(file) }.value
                    state = .obtained(file)
                } catch {
                    state = .rejected(file.lastPathComponent, error.localizedDescription)
                }
            }
            return
        }
        state = .testing(file.lastPathComponent)
        Task {
            let result = await InstallerLinkTest.test(captured)
            state = .result(captured, result)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progress = nil
        state = .browsing
        message = "The download stopped: \(error.localizedDescription)"
    }
}

/// Back, forward, reload and the address of the capture browser.
struct BrowserAddressBar: View {
    @Bindable var capture: InstallerCaptureModel

    var body: some View {
        HStack(spacing: 8) {
            Button { capture.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!capture.canGoBack)
                .help("Back")
            Button { capture.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!capture.canGoForward)
                .help("Forward")
            Button { capture.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            TextField("The publisher's download page, https://…", text: $capture.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { capture.open(capture.address) }
            if capture.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(10)
    }
}

/// Hosts the capture model's web view.
struct WebViewHost: NSViewRepresentable {
    let capture: InstallerCaptureModel
    func makeNSView(context: Context) -> WKWebView { capture.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
