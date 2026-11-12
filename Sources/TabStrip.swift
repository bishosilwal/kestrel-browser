import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripDidSelect(index: Int)
    func tabStripDidRequestClose(index: Int)
    func tabStripDidRequestNewTab()
    /// Title/handler pairs for a tab's right-click menu; "-" means a separator.
    func tabStripContextActions(index: Int) -> [(String, () -> Void)]
    func tabStripDidRequestMove(from: Int, to: Int)
}

/// One view per tab, everything drawn by hand. A stock NSTableView or NSSegmented
/// control would add layers, cells and layout passes we do not need.
final class TabItemView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var favicon: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isHibernated = false { didSet { needsDisplay = true } }
    var isLoading = false { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if isLoading { needsDisplay = true } } }
    var isPrivate = false { didSet { needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var closeHovering = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var contextActions: [(String, () -> Void)] = []
    /// Drag-to-reorder. The strip owns the reordering logic; the item only reports
    /// where the press started and where the pointer is now.
    var onDragBegan: ((CGFloat) -> Void)?      // press x within this item
    var onDragChanged: ((NSPoint) -> Void)?    // pointer, window coordinates
    var onDragEnded: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    private var showsTitle: Bool { bounds.width >= 76 }
    private var showsClose: Bool { bounds.width >= 58 && (hovering || isSelected) }
    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; closeHovering = false }
    override func mouseMoved(with event: NSEvent) {
        closeHovering = closeRect.contains(convert(event.locationInWindow, from: nil))
    }

    private var pressPoint: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showsClose, closeRect.contains(p) { onClose?(); return }
        if event.type == .otherMouseDown { onClose?(); return }
        pressPoint = p
        onSelect?()   // select on press, like Safari, so dragging the current tab feels direct
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressPoint else { return }
        let here = convert(event.locationInWindow, from: nil)
        if !dragging, abs(here.x - press.x) > 5 {
            dragging = true
            onDragBegan?(press.x)
        }
        if dragging { onDragChanged?(event.locationInWindow) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDragEnded?() }
        pressPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }  // middle-click closes

    override func rightMouseDown(with event: NSEvent) {
        guard !contextActions.isEmpty else { return super.rightMouseDown(with: event) }
        let menu = NSMenu()
        for (i, entry) in contextActions.enumerated() {
            if entry.0 == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.0, action: #selector(runContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func runContextAction(_ sender: NSMenuItem) {
        guard contextActions.indices.contains(sender.tag) else { return }
        contextActions[sender.tag].1()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.14).setFill()
            path.fill()
        }

        var x = r.minX + 8.0
        let iconSize: CGFloat = 16
        let iconY = (bounds.height - iconSize) / 2

        if isLoading {
            // A quiet arc instead of a spinning NSProgressIndicator: no timer, no layer.
            let c = NSPoint(x: x + iconSize / 2, y: bounds.midY)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: 6, startAngle: 0, endAngle: 360)
            NSColor.tertiaryLabelColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 6, startAngle: 90,
                          endAngle: 90 - CGFloat(360 * max(0.08, progress)), clockwise: true)
            NSColor.controlAccentColor.setStroke()
            arc.lineWidth = 2
            arc.stroke()
            x += iconSize + 6
        } else if let icon = favicon {
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            if isHibernated {
                NSGraphicsContext.current?.saveGraphicsState()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += iconSize + 6
        } else {
            // Letter tile fallback so tabs never look empty.
            let letter = String(title.first.map(String.init)?.uppercased() ?? "\u{2022}")
            let rect = NSRect(x: x, y: iconY, width: iconSize, height: iconSize)
            let bg = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.tertiaryLabelColor.withAlphaComponent(isHibernated ? 0.2 : 0.35).setFill()
            bg.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            x += iconSize + 6
        }

        if showsTitle {
            let rightPad: CGFloat = showsClose ? 26 : 8
            let width = max(0, r.maxX - x - rightPad)
            if width > 8 {
                let color: NSColor = isSelected ? .labelColor
                    : (isHibernated ? .tertiaryLabelColor : .secondaryLabelColor)
                let ps = NSMutableParagraphStyle()
                ps.lineBreakMode = .byTruncatingTail
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
                    .foregroundColor: color,
                    .paragraphStyle: ps,
                ]
                let s = NSAttributedString(string: title, attributes: attrs)
                let h = s.size().height
                s.draw(with: NSRect(x: x, y: bounds.midY - h / 2, width: width, height: h),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }

        if isPrivate {
            let dot = NSBezierPath(ovalIn: NSRect(x: r.minX + 3, y: r.minY + 3, width: 5, height: 5))
            NSColor.systemPurple.setFill()
            dot.fill()
        }

        if showsClose {
            let cr = closeRect
            if closeHovering {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
            }
            let inset = cr.insetBy(dx: 4.5, dy: 4.5)
            let x1 = NSBezierPath()
            x1.move(to: NSPoint(x: inset.minX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            x1.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            x1.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            (closeHovering ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
            x1.lineWidth = 1.3
            x1.lineCapStyle = .round
            x1.stroke()
        }
    }
}

final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?
    private var items: [TabItemView] = []
    private var dragIndex: Int?
    private var dragGrabX: CGFloat = 0     // where in the tab the press landed
    private var dragPointerX: CGFloat = 0  // pointer, strip coordinates

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild only when the tab count changes; otherwise update in place so
    /// typing in a page title does not churn the view hierarchy.
    func update(tabs: [Tab], selected: Int) {
        if items.count != tabs.count {
            items.forEach { $0.removeFromSuperview() }
            items = tabs.indices.map { i in
                let v = TabItemView()
                v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
                v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
                addSubview(v)
                return v
            }
        }
        for (i, tab) in tabs.enumerated() {
            let v = items[i]
            v.onSelect = { [weak self] in self?.delegate?.tabStripDidSelect(index: i) }
            v.onClose = { [weak self] in self?.delegate?.tabStripDidRequestClose(index: i) }
            v.title = tab.displayTitle
            v.favicon = tab.favicon
            v.isSelected = (i == selected)
            v.isHibernated = tab.isHibernated
            v.isLoading = tab.isLoading
            v.progress = tab.progress
            v.isPrivate = tab.isPrivate
            v.contextActions = delegate?.tabStripContextActions(index: i) ?? []
            v.onDragBegan = { [weak self] grabX in self?.beginDrag(i, grabX: grabX) }
            v.onDragChanged = { [weak self] p in self?.updateDrag(p) }
            v.onDragEnded = { [weak self] in self?.endDrag() }
            v.toolTip = tab.isHibernated
                ? "\(tab.displayTitle) \u{2014} sleeping (0 MB)"
                : tab.url?.absoluteString ?? tab.displayTitle
        }
        layoutTabs()
    }

    /// Width per tab. Tabs shrink as far as they must so that every tab stays on
    /// screen and clickable -- a lower bound here would push the last tabs past the
    /// window edge where they cannot be reached at all.
    private func tabWidth(available: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return min(210, available / CGFloat(items.count))
    }

    private func layoutTabs() {
        let available = max(0, bounds.width - 6)
        guard !items.isEmpty else { return }
        let w = tabWidth(available: available)
        var x: CGFloat = 0
        for (i, v) in items.enumerated() {
            if i == dragIndex { x += w; continue }   // positioned below, on top of the rest
            v.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w
        }
        if let d = dragIndex, items.indices.contains(d) {
            let clamped = max(0, min(available - w, dragPointerX - dragGrabX))
            items[d].frame = NSRect(x: clamped, y: 0, width: w, height: bounds.height)
        }
    }

    // MARK: - Drag to reorder

    private func beginDrag(_ index: Int, grabX: CGFloat) {
        guard items.indices.contains(index) else { return }
        dragIndex = index
        dragGrabX = grabX
        dragPointerX = items[index].frame.minX + grabX
        addSubview(items[index])          // raise above its neighbours while moving
    }

    private func updateDrag(_ pointerInWindow: NSPoint) {
        guard let from = dragIndex else { return }
        dragPointerX = convert(pointerInWindow, from: nil).x
        let available = max(0, bounds.width - 6)
        let w = tabWidth(available: available)
        guard w > 0 else { return }

        let leadingEdge = dragPointerX - dragGrabX
        let to = max(0, min(items.count - 1, Int(((leadingEdge + w / 2) / w).rounded(.down))))
        if to != from {
            dragIndex = to
            // The delegate reorders and calls update(), which re-lays out around the
            // dragged tab; grabX is preserved so the tab stays under the pointer.
            delegate?.tabStripDidRequestMove(from: from, to: to)
        }
        layoutTabs()
    }

    private func endDrag() {
        dragIndex = nil
        layoutTabs()
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// Double-clicking empty strip space opens a tab, as in every other browser. Single
    /// clicks fall through so the window can still be dragged by its top bar.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            delegate?.tabStripDidRequestNewTab()
            return
        }
        super.mouseDown(with: event)
    }
}

/// 2px determinate bar under the toolbar. Hidden at rest so there is nothing to animate.
final class ProgressBar: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { isHidden = !active; needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.02, progress)), height: bounds.height).fill()
    }
}
