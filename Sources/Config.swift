import Foundation

/// User-editable settings, read from ~/Library/Application Support/Lantern/config.json
/// Missing file => defaults. Nothing here requires a rebuild to change.
final class Config {
    static let shared = Config()

    var searchTemplate: String = "https://www.google.com/search?q=%s"
    var homepage: String = "about:blank"
    /// Minutes a background tab may sit before its web process is destroyed. 0 = never.
    var hibernateAfterMinutes: Double = 5
    /// Hibernate every background tab immediately when the OS reports memory pressure.
    var hibernateOnMemoryPressure: Bool = true
    var blockAdsAndTrackers: Bool = true
    var restoreSessionOnLaunch: Bool = true
    var showMemoryReadout: Bool = true
    var enableDeveloperTools: Bool = true

    static var supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lantern", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var fileURL: URL { Config.supportDir.appendingPathComponent("config.json") }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            save()  // materialize the file so it is discoverable and editable
            return
        }
        if let v = d["searchTemplate"] as? String { searchTemplate = v }
        if let v = d["homepage"] as? String { homepage = v }
        if let v = d["hibernateAfterMinutes"] as? Double { hibernateAfterMinutes = v }
        if let v = d["hibernateOnMemoryPressure"] as? Bool { hibernateOnMemoryPressure = v }
        if let v = d["blockAdsAndTrackers"] as? Bool { blockAdsAndTrackers = v }
        if let v = d["restoreSessionOnLaunch"] as? Bool { restoreSessionOnLaunch = v }
        if let v = d["showMemoryReadout"] as? Bool { showMemoryReadout = v }
        if let v = d["enableDeveloperTools"] as? Bool { enableDeveloperTools = v }
    }

    func save() {
        let d: [String: Any] = [
            "searchTemplate": searchTemplate,
            "homepage": homepage,
            "hibernateAfterMinutes": hibernateAfterMinutes,
            "hibernateOnMemoryPressure": hibernateOnMemoryPressure,
            "blockAdsAndTrackers": blockAdsAndTrackers,
            "restoreSessionOnLaunch": restoreSessionOnLaunch,
            "showMemoryReadout": showMemoryReadout,
            "enableDeveloperTools": enableDeveloperTools,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Turn whatever the user typed into something loadable: URL, bare host, or search.
    func resolve(input raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        if s.lowercased().hasPrefix("about:") || s.lowercased().hasPrefix("file:") { return URL(string: s) }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           scheme == "http" || scheme == "https", u.host != nil { return u }

        // A bare host: no spaces and a dot that looks like a TLD, or localhost[:port].
        let looksLikeHost = !s.contains(" ")
            && (s.range(of: #"^[\w.-]+\.[a-zA-Z]{2,}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || s.range(of: #"^localhost(:\d+)?(/.*)?$"#, options: .regularExpression) != nil)
        if looksLikeHost { return URL(string: "https://" + s) }

        let q = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }
}
