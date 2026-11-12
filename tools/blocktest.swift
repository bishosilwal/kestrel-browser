// Functional test for the content blocker: compiles the real blocklist, attaches it to
// an offscreen WKWebView, then asks the page to fetch a set of URLs and reports which
// ones WebKit refused. Run via tools/run-blocktest.sh
import AppKit
import WebKit

setvbuf(stdout, nil, _IONBF, 0)

let PROBES = [
    ("https://www.google-analytics.com/analytics.js", true),
    ("https://securepubads.g.doubleclick.net/tag/js/gpt.js", true),
    ("https://connect.facebook.net/en_US/fbevents.js", true),
    ("https://static.hotjar.com/c/hotjar-1.js", true),
    ("https://cdn.taboola.com/libtrc/x/loader.js", true),
    ("https://example.com/", false),
    ("https://en.wikipedia.org/robots.txt", false),
]

func escape(_ s: String) -> String {
    var out = ""
    for ch in s { if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }; out.append(ch) }
    return out
}

let listPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/blocked-domains.txt"
let text = try! String(contentsOfFile: listPath, encoding: .utf8)
let domains = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }

var rules: [[String: Any]] = domains.map { entry in
    let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    var filter = "^[^:]+://+([^:/?#]+\\.)?" + escape(String(parts[0]))
    if parts.count > 1, !parts[1].isEmpty { filter += "(:[0-9]+)?/" + escape(String(parts[1])) }
    else { filter += "[:/]" }
    return ["trigger": ["url-filter": filter], "action": ["type": "block"]]
}
let json = String(decoding: try! JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
print("compiled from \(domains.count) domains -> \(rules.count) rules")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Runner: NSObject, WKNavigationDelegate {
    var webView: WKWebView!
    func start(_ list: WKContentRuleList) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(list)
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
        webView.navigationDelegate = self
        webView.loadHTMLString("<html><body>probe</body></html>", baseURL: URL(string: "https://example.org/"))
    }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) { probe(0, failures: 0) }

    func probe(_ i: Int, failures: Int) {
        guard i < PROBES.count else {
            print(failures == 0 ? "\nRESULT: PASS \u{2014} every probe behaved as expected"
                                : "\nRESULT: FAIL \u{2014} \(failures) probe(s) wrong")
            exit(failures == 0 ? 0 : 1)
        }
        let (url, shouldBlock) = PROBES[i]
        // callAsyncJavaScript takes a function *body*, so this must `return` directly.
        let js = """
        try { await fetch("\(url)", {mode: 'no-cors', cache: 'no-store'}); return "ok"; }
        catch (e) { return "blocked"; }
        """
        webView.callAsyncJavaScript(js, in: nil, in: .page) { result in
            var outcome = "error"
            if case .success(let v) = result, let s = v as? String { outcome = s }
            let blocked = (outcome == "blocked")
            let ok = blocked == shouldBlock
            let host = URL(string: url)?.host ?? url
            let pad = host.padding(toLength: max(host.count, 34), withPad: " ", startingAt: 0)
            let want = (shouldBlock ? "blocked" : "allowed").padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  \(ok ? "\u{2713}" : "\u{2717}") \(pad) expect \(want) got \(outcome)")
            self.probe(i + 1, failures: failures + (ok ? 0 : 1))
        }
    }
}

let runner = Runner()
WKContentRuleListStore.default()?.compileContentRuleList(
    forIdentifier: "lantern-blocktest", encodedContentRuleList: json) { list, error in
    if let error { print("compile failed: \(error)"); exit(2) }
    guard let list else { print("no list"); exit(2) }
    print("rule list compiled ok\n")
    runner.start(list)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("TIMEOUT"); exit(3) }
app.run()
