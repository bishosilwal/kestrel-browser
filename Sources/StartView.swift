import AppKit

/// The new-tab page, drawn natively. A blank tab in Lantern allocates no web
/// process at all -- there is literally nothing to load.
final class StartView: NSView {
    var onOpen: ((String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "Lantern 🏮")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        addSubview(title)

        let sub = NSTextField(labelWithString: "\u{2318}L to go somewhere")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .tertiaryLabelColor
        sub.alignment = .center
        addSubview(sub)

        // Top sites by visit count, one entry per host.
        var seenHosts = Set<String>()
        var top: [(host: String, url: String)] = []
        for e in Store.shared.history.sorted(by: { $0.visits > $1.visits }) {
            guard let h = URL(string: e.url)?.host else { continue }
            let clean = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            if seenHosts.contains(clean) { continue }
            seenHosts.insert(clean)
            top.append((clean, "https://" + h + "/"))
            if top.count == 10 { break }
        }

        for site in top {
            let b = NSButton(title: site.host, target: self, action: #selector(openSite(_:)))
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = .secondaryLabelColor
            b.identifier = NSUserInterfaceItemIdentifier(site.url)
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
            b.layer?.cornerRadius = 8
            addSubview(b)
        }
        needsLayout = true
    }

    @objc private func openSite(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpen?(id) }
    }

    override func layout() {
        super.layout()
        let labels = subviews.compactMap { $0 as? NSTextField }
        let buttons = subviews.compactMap { $0 as? NSButton }

        let centerY = bounds.height * 0.34
        if labels.count >= 2 {
            labels[0].frame = NSRect(x: 0, y: centerY, width: bounds.width, height: 38)
            labels[1].frame = NSRect(x: 0, y: centerY + 40, width: bounds.width, height: 18)
        }

        guard !buttons.isEmpty else { return }
        // Center a wrapping row of pills under the title.
        let perRow = max(1, min(5, Int(bounds.width / 150)))
        let bw: CGFloat = 132, bh: CGFloat = 30, gap: CGFloat = 10
        var i = 0
        while i < buttons.count {
            let rowCount = min(perRow, buttons.count - i)
            let rowWidth = CGFloat(rowCount) * bw + CGFloat(rowCount - 1) * gap
            var x = (bounds.width - rowWidth) / 2
            let y = centerY + 84 + CGFloat(i / perRow) * (bh + gap)
            for j in 0..<rowCount {
                buttons[i + j].frame = NSRect(x: x, y: y, width: bw, height: bh)
                x += bw + gap
            }
            i += rowCount
        }
    }
}

/// URL field that gives the page its focus back on Escape and selects all on focus.
final class URLField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return ok
    }
}
