import AppKit
import WebKit

protocol TabDelegate: AnyObject {
    func tabDidChangeState(_ tab: Tab)
    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab?
    func tabRequestsClose(_ tab: Tab)
    func tabStatus(_ tab: Tab, message: String?)
}

/// Shared WebKit plumbing. A single data store across every tab means one cookie
/// and cache jar; WebKit itself decides how to pool content processes.
enum WebKitEnv {
    static func makeConfiguration(private isPrivate: Bool = false) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        // Identify as Safari: many sites gate features on the UA and WKWebView's
        // default string has no Version/Safari suffix.
        cfg.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // No autoplay. This alone removes a large share of background CPU and decode memory.
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.suppressesIncrementalRendering = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if let list = ContentBlocker.ruleList {
            cfg.userContentController.add(list)
        }
        return cfg
    }
}

final class Tab: NSObject {
    let id = UUID()
    weak var delegate: TabDelegate?
    let isPrivate: Bool

    /// nil while hibernated. Creating this is what allocates a WebKit content process.
    private(set) var webView: WKWebView?

    var url: URL?
    var title: String = ""
    var favicon: NSImage?
    var isLoading = false
    var progress: Double = 0
    var lastActive = Date()
    var isHibernated: Bool { webView == nil }
    var hasEverLoaded = false

    /// Full session snapshot (back/forward list + scroll offset) kept while hibernated.
    private var savedInteractionState: Data?
    private var pendingURL: URL?
    /// For window.open/target=_blank: WebKit requires the new web view be built from the
    /// exact configuration it handed us, and it performs the navigation itself.
    private var providedConfiguration: WKWebViewConfiguration?
    private var webKitWillLoad = false
    private var observations: [NSKeyValueObservation] = []
    private static var faviconCache: [String: NSImage] = [:]

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "New Tab"
    }

    init(url: URL?, isPrivate: Bool = false, delegate: TabDelegate?,
         configuration: WKWebViewConfiguration? = nil) {
        self.isPrivate = isPrivate
        self.delegate = delegate
        self.url = url
        self.pendingURL = url
        self.providedConfiguration = configuration
        self.webKitWillLoad = (configuration != nil)
        super.init()
        if let url { self.favicon = Tab.faviconCache[url.host ?? ""] }
    }

    /// Restore from a previous session without spending a web process yet.
    init(saved: SavedTab, delegate: TabDelegate?) {
        self.isPrivate = false
        self.delegate = delegate
        self.url = URL(string: saved.url)
        self.title = saved.title
        self.savedInteractionState = saved.interactionState
        self.pendingURL = URL(string: saved.url)
        super.init()
        self.favicon = Tab.faviconCache[self.url?.host ?? ""]
    }

    func snapshot() -> SavedTab {
        SavedTab(url: url?.absoluteString ?? "",
                 title: title,
                 interactionState: liveInteractionState() ?? savedInteractionState)
    }

    private func liveInteractionState() -> Data? {
        webView?.interactionState as? Data
    }

    // MARK: - Lifecycle

    /// Creates the web view on demand. Called when the tab is first shown or woken.
    @discardableResult
    func ensureLoaded() -> WKWebView {
        if let webView { return webView }

        let cfg = providedConfiguration ?? WebKitEnv.makeConfiguration(private: isPrivate)
        providedConfiguration = nil
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.allowsLinkPreview = true
        wv.autoresizingMask = [.width, .height]
        if Config.shared.enableDeveloperTools, #available(macOS 13.3, *) { wv.isInspectable = true }
        webView = wv
        observe(wv)

        if webKitWillLoad {
            // WebKit drives the first navigation for opener-created views.
            webKitWillLoad = false
        } else if let state = savedInteractionState {
            // Restores the whole back/forward list and scroll position, then refetches.
            wv.interactionState = state
            savedInteractionState = nil
            if wv.url == nil, let u = pendingURL { wv.load(URLRequest(url: u)) }
        } else if let u = pendingURL {
            wv.load(URLRequest(url: u))
        }
        pendingURL = nil
        hasEverLoaded = true
        return wv
    }

    /// Tears the web process down entirely, keeping only enough state to come back.
    /// This is the difference between a background tab costing ~100 MB and ~2 KB.
    func hibernate() {
        guard let wv = webView else { return }
        if wv.url != nil { url = wv.url }
        savedInteractionState = liveInteractionState()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.stopLoading()
        wv.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        pendingURL = url
        delegate?.tabDidChangeState(self)
    }

    /// True when this tab is safe to hibernate right now.
    func canHibernate(idleFor seconds: TimeInterval) -> Bool {
        guard webView != nil else { return false }
        if isPlayingMedia { return false }
        return Date().timeIntervalSince(lastActive) >= seconds
    }

    private var isPlayingMedia: Bool {
        // Never kill a tab that is capturing or playing.
        guard let wv = webView else { return false }
        if wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none { return true }
        let sel = Selector(("_isPlayingAudio"))
        guard wv.responds(to: sel) else { return false }
        return wv.value(forKey: "_isPlayingAudio") as? Bool ?? false
    }

    func load(_ url: URL) {
        self.url = url
        savedInteractionState = nil
        if let wv = webView {
            wv.load(URLRequest(url: url))
        } else {
            pendingURL = url
            ensureLoaded()
        }
    }

    func reload() {
        guard let wv = webView else { ensureLoaded(); return }
        wv.reloadFromOrigin()
    }

    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }

    // MARK: - Observation

    private func observe(_ wv: WKWebView) {
        func note() { delegate?.tabDidChangeState(self) }
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                if let t = w.title, !t.isEmpty {
                    self.title = t
                    if let u = w.url { Store.shared.updateTitle(url: u, title: t) }
                }
                note()
            },
            wv.observe(\.url, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.url = w.url
                note()
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.isLoading = w.isLoading
                note()
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                guard let self else { return }
                self.progress = w.estimatedProgress
                note()
            },
            wv.observe(\.canGoBack, options: [.new]) { _, _ in note() },
            wv.observe(\.canGoForward, options: [.new]) { _, _ in note() },
        ]
    }

    deinit { observations.forEach { $0.invalidate() } }

    // MARK: - Favicon

    private func fetchFavicon(for wv: WKWebView) {
        guard let host = wv.url?.host else { return }
        if let cached = Tab.faviconCache[host] { favicon = cached; delegate?.tabDidChangeState(self); return }

        let js = """
        (function(){var l=document.querySelector("link[rel~='icon']")||document.querySelector("link[rel='shortcut icon']");
        return l&&l.href?l.href:location.origin+'/favicon.ico';})()
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let href = result as? String, let iconURL = URL(string: href) else { return }
            var req = URLRequest(url: iconURL)
            req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let img = NSImage(data: data), img.size.width > 0 else { return }
                img.size = NSSize(width: 16, height: 16)
                DispatchQueue.main.async {
                    Tab.faviconCache[host] = img
                    self.favicon = img
                    self.delegate?.tabDidChangeState(self)
                }
            }.resume()
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        // Hand off anything WebKit does not speak (mailto:, tel:, zoommtg:, ...) to the OS.
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // Cmd-click / middle-click opens a background tab, like every other browser.
        if action.navigationType == .linkActivated {
            let flags = action.modifierFlags
            if flags.contains(.command) || action.buttonNumber == 2 {
                _ = delegate?.tab(self, openNewTabWith: url, configuration: nil,
                                  activate: flags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, !isPrivate {
            Store.shared.recordVisit(url: u, title: webView.title ?? "")
        }
        fetchFavicon(for: webView)
        delegate?.tabDidChangeState(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let ns = error as NSError
        // -999 is "cancelled", which happens on every normal redirect/stop.
        guard ns.code != NSURLErrorCancelled else { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? url?.absoluteString ?? ""
        let host = URL(string: failing)?.host ?? failing
        let html = """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
        <style>
        :root{color-scheme:light dark}
        body{font:15px/1.55 -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;
        color:#111;background:#fff}
        @media(prefers-color-scheme:dark){body{color:#eee;background:#1c1c1e}}
        .c{max-width:30rem;padding:2rem;text-align:center}
        h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}
        p{opacity:.65;margin:0 0 1.5rem}
        button{font:inherit;padding:.5rem 1.1rem;border-radius:7px;border:0;background:#0a84ff;color:#fff;cursor:pointer}
        code{opacity:.5;font-size:.8rem}
        </style>
        <div class=c><h1>Can\u{2019}t open \(host)</h1>
        <p>\(ns.localizedDescription)</p>
        <button onclick="location.reload()">Try again</button>
        <p><code>\(ns.domain) \(ns.code)</code></p></div>
        """
        webView.loadHTMLString(html, baseURL: URL(string: failing))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The content process was killed (usually by memory pressure). Recover in place.
        NSLog("Lantern: content process terminated for \(url?.host ?? "?"), reloading")
        webView.reload()
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open must reuse the supplied configuration.
        let tab = delegate?.tab(self, openNewTabWith: action.request.url, configuration: configuration, activate: true)
        return tab?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabRequestsClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            completionHandler(r == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = "use your camera"
        case .microphone: what = "use your microphone"
        case .cameraAndMicrophone: what = "use your camera and microphone"
        @unknown default: what = "use a capture device"
        }
        let a = NSAlert()
        a.messageText = "Allow \(origin.host) to \(what)?"
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don\u{2019}t Allow")
        a.beginSheetModal(for: webView.window ?? NSApp.keyWindow ?? NSWindow()) { r in
            decisionHandler(r == .alertFirstButtonReturn ? .grant : .deny)
        }
    }

}
