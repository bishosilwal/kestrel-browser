import Foundation
import WebKit
import CryptoKit

/// Compiles the plain-text domain list into a native WKContentRuleList.
///
/// This is the cheapest possible ad blocker: the rules are compiled once into a
/// bytecode program that runs inside WebKit's networking layer, so blocked
/// requests never reach the content process at all. No JS, no extension host,
/// no per-page CPU cost -- unlike Chrome extensions, which run in their own
/// process and re-evaluate on every request.
enum ContentBlocker {

    static private(set) var ruleList: WKContentRuleList?
    static private(set) var ruleCount: Int = 0

    /// Conservative cosmetic rules for slots that survive network blocking as blank gaps.
    private static let cosmeticSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_iframe\"]",
        "[id^=\"div-gpt-ad\"]", "iframe[src*=\"doubleclick.net\"]",
        "iframe[src*=\"googlesyndication.com\"]", "#taboola-below-article-thumbnails",
        ".trc_related_container", ".OUTBRAIN", "[data-ad-slot]", "[data-ad-client]",
    ]

    static func domainListURL() -> URL? {
        let userCopy = Config.supportDir.appendingPathComponent("blocked-domains.txt")
        if FileManager.default.fileExists(atPath: userCopy.path) { return userCopy }
        guard let bundled = Bundle.main.url(forResource: "blocked-domains", withExtension: "txt") else { return nil }
        // Seed a user-editable copy on first run, then use it from here on.
        try? FileManager.default.copyItem(at: bundled, to: userCopy)
        return FileManager.default.fileExists(atPath: userCopy.path) ? userCopy : bundled
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func buildJSON(from domains: [String]) -> String {
        var rules: [[String: Any]] = []
        for entry in domains {
            let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let host = String(parts[0])
            var filter = "^[^:]+://+([^:/?#]+\\.)?" + escape(host)
            if parts.count > 1, !parts[1].isEmpty {
                filter += "(:[0-9]+)?/" + escape(String(parts[1]))
            } else {
                filter += "[:/]"
            }
            rules.append([
                "trigger": ["url-filter": filter],
                "action": ["type": "block"],
            ])
        }
        // One combined cosmetic rule keeps the compiled program small.
        rules.append([
            "trigger": ["url-filter": ".*", "resource-type": ["document"]],
            "action": ["type": "css-display-none", "selector": cosmeticSelectors.joined(separator: ", ")],
        ])
        ruleCount = rules.count
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Compiles (or reuses a cached compilation of) the rule list keyed by content hash,
    /// so editing the domain list recompiles but ordinary launches do not.
    static func load(completion: @escaping (WKContentRuleList?) -> Void) {
        guard Config.shared.blockAdsAndTrackers else { completion(nil); return }
        guard let url = domainListURL(), let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Lantern: no blocklist found")
            completion(nil); return
        }
        let domains = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !domains.isEmpty else { completion(nil); return }

        let json = buildJSON(from: domains)
        let digest = SHA256.hash(data: Data(json.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let identifier = "lantern-block-" + digest.prefix(16)
        let store = WKContentRuleListStore.default()

        store?.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                ruleList = list
                completion(list)
                return
            }
            store?.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Lantern: blocklist compile failed: \(error.localizedDescription)") }
                ruleList = list
                completion(list)
            }
        }
    }
}
