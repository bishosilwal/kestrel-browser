import AppKit
import WebKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    private(set) var tabs: [Tab] = []
    private(set) var activeIndex = 0
    let isPrivateWindow: Bool

    private let root = FlippedView()
    private let tabStrip = TabStripView()
    private let toolbarRow = FlippedView()
    private let progressBar = ProgressBar()
    private let webContainer = FlippedView()
    private let startView = StartView()

    private let chromeBackground = NSVisualEffectView()
    private let hairline = HairlineView()

    private var backButton: ToolbarButton!
    private var forwardButton: ToolbarButton!
    private var reloadButton: ToolbarButton!
    private var shieldButton: ToolbarButton!
    private var bookmarkButton: ToolbarButton!
    private let urlBar = URLBar()
    private var urlField: URLField { urlBar.field }
    private let statusPill = StatusPill()
    private let plusButton = NSButton()

    private let findRow = BarBackgroundView()
    private let findField = NSTextField()
    private let findCount = NSTextField(labelWithString: "")
    private var findPrevButton: ToolbarButton!
    private var findNextButton: ToolbarButton!
    private let findDoneButton = NSButton()
    private var findVisible = false

    private var hibernationTimer: Timer?
    private var memoryTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var sessionSaveScheduled = false
    private var suppressCompletion = false
    private var statusResetWork: DispatchWorkItem?
    /// Most recently closed tabs, for Reopen Closed Tab.
    private var closedTabs: [SavedTab] = []

    private let chromeTopHeight: CGFloat = 36 + 38
    private var findRowHeight: CGFloat { findVisible ? 34 : 0 }

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    // MARK: - Init

    init(isPrivate: Bool = false) {
        self.isPrivateWindow = isPrivate
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init(window: w)

        w.delegate = self
        w.title = isPrivate ? "Lantern Private" : "Lantern 🏮"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 520, height: 380)
        w.tabbingMode = .disallowed          // we manage our own tabs
        w.setFrameAutosaveName(isPrivate ? "LanternPrivateWindow" : "LanternWindow")
        w.backgroundColor = .windowBackgroundColor
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }

        buildChrome()
        w.contentView = root

        startHibernationTimer()
        startMemoryReadout()
        installMemoryPressureHandling()

        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Chrome

    private func buildChrome() {
        // One vibrant layer behind the whole chrome gives the standard native toolbar
        // look for the cost of a single layer.
        chromeBackground.material = .titlebar
        chromeBackground.blendingMode = .withinWindow
        chromeBackground.state = .followsWindowActiveState
        root.addSubview(chromeBackground)

        root.addSubview(tabStrip)
        root.addSubview(toolbarRow)
        root.addSubview(progressBar)
        root.addSubview(findRow)
        root.addSubview(hairline)
        root.addSubview(webContainer)

        tabStrip.delegate = self
        progressBar.active = false
        findRow.isHidden = true

        backButton = ToolbarButton(symbol: "chevron.backward", tip: "Back (\u{2318}[)",
                                   target: self, action: #selector(goBack))
        forwardButton = ToolbarButton(symbol: "chevron.forward", tip: "Forward (\u{2318}])",
                                      target: self, action: #selector(goForward))
        reloadButton = ToolbarButton(symbol: "arrow.clockwise", tip: "Reload (\u{2318}R)",
                                     target: self, action: #selector(reloadOrStop))
        bookmarkButton = ToolbarButton(symbol: "star", tip: "Bookmark (\u{2318}D)",
                                       target: self, action: #selector(toggleBookmark))
        bookmarkButton.onTint = .systemYellow
        shieldButton = ToolbarButton(symbol: "shield.lefthalf.filled",
                                     tip: "Ad & tracker blocking",
                                     target: self, action: #selector(toggleBlocking))

        // The new-tab `+` moved here from the tab strip: same control, same glyph, same tip.
        plusButton.bezelStyle = .accessoryBarAction
        plusButton.isBordered = false
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        plusButton.imageScaling = .scaleProportionallyDown
        plusButton.target = self
        plusButton.action = #selector(newTabFromToolbar)
        plusButton.toolTip = "New Tab (\u{2318}T)"

        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(urlFieldCommitted)
        urlField.onCancel = { [weak self] in
            guard let self else { return }
            self.urlField.stringValue = self.activeTab?.url
                .map { Store.displayForm($0.absoluteString) } ?? ""
            self.focusWebContent()
        }

        [backButton, forwardButton, urlBar, reloadButton, bookmarkButton,
         shieldButton, statusPill, plusButton].forEach { toolbarRow.addSubview($0!) }

        // Find bar
        findField.placeholderString = "Find on page"
        findField.font = .systemFont(ofSize: 12)
        findField.bezelStyle = .roundedBezel
        findField.target = self
        findField.action = #selector(findNext)
        findCount.font = .systemFont(ofSize: 11)
        findCount.textColor = .secondaryLabelColor
        findPrevButton = ToolbarButton(symbol: "chevron.up", tip: "Previous (\u{2318}\u{21E7}G)",
                                       target: self, action: #selector(findPrevious), pointSize: 11)
        findNextButton = ToolbarButton(symbol: "chevron.down", tip: "Next (\u{2318}G)",
                                       target: self, action: #selector(findNext), pointSize: 11)
        findDoneButton.title = "Done"
        findDoneButton.bezelStyle = .rounded
        findDoneButton.controlSize = .small
        findDoneButton.target = self
        findDoneButton.action = #selector(hideFindBar)
        [findField, findPrevButton, findNextButton, findCount, findDoneButton]
            .forEach { findRow.addSubview($0!) }

        startView.onOpen = { [weak self] urlString in
            guard let self, let u = URL(string: urlString) else { return }
            self.activeTab?.load(u)
            self.refreshChrome()
            self.attachActiveTab()
        }
    }

    override func windowDidLoad() { super.windowDidLoad() }

    private func layoutChrome() {
        let b = root.bounds
        // Safari's stacking: the toolbar is the top row and the traffic lights sit over it,
        // with the tab strip running the full width beneath.
        let trafficLightInset: CGFloat = 82
        let sidebarSlot: CGFloat = 30   // empty slot where Safari's sidebar toggle would be
        let tabRow: CGFloat = 36
        let toolRow: CGFloat = 40

        toolbarRow.frame = NSRect(x: 0, y: 0, width: b.width, height: toolRow)
        tabStrip.frame = NSRect(x: 0, y: toolRow, width: b.width, height: tabRow)
        progressBar.frame = NSRect(x: 0, y: chromeTopHeight - 3, width: b.width, height: 3)

        findRow.frame = NSRect(x: 0, y: chromeTopHeight, width: b.width, height: findRowHeight)
        findRow.isHidden = !findVisible

        let chromeBottom = chromeTopHeight + findRowHeight
        chromeBackground.frame = NSRect(x: 0, y: 0, width: b.width, height: chromeBottom)
        hairline.frame = NSRect(x: 0, y: chromeBottom - 1, width: b.width, height: 1)

        webContainer.frame = NSRect(x: 0, y: chromeBottom, width: b.width,
                                    height: max(0, b.height - chromeBottom))
        startView.frame = webContainer.bounds
        activeTab?.webView?.frame = webContainer.bounds

        // Toolbar row internals. Buttons get a 30x28 hit area so the hover highlight
        // reads as a real target rather than a tight box around the glyph.
        let bw: CGFloat = 30, bh: CGFloat = 28
        let y = (toolRow - bh) / 2
        // Left cluster: clears the traffic lights, then leaves Safari's sidebar slot empty.
        let leftStart = trafficLightInset + sidebarSlot
        backButton.frame = NSRect(x: leftStart, y: y, width: bw, height: bh)
        forwardButton.frame = NSRect(x: leftStart + bw + 2, y: y, width: bw, height: bh)

        // Right cluster, filled from the trailing edge: + , pill, shield, bookmark, reload.
        var right = b.width - 12
        plusButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        if Config.shared.showMemoryReadout {
            statusPill.isHidden = false
            let w = max(64, min(190, statusPill.fittingWidth))
            statusPill.frame = NSRect(x: right - w, y: 0, width: w, height: toolRow)
            right -= w + 4
        } else {
            statusPill.isHidden = true
        }
        shieldButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        bookmarkButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 2
        reloadButton.frame = NSRect(x: right - bw, y: y, width: bw, height: bh)
        right -= bw + 10

        // Address field flexes between the clusters, with an equal margin on each side.
        let urlX = forwardButton.frame.maxX + 10
        let fieldH: CGFloat = 28
        urlBar.frame = NSRect(x: urlX, y: (toolRow - fieldH) / 2,
                              width: max(90, right - urlX), height: fieldH)

        // Find row internals
        if findVisible {
            findField.frame = NSRect(x: 14, y: 5, width: 250, height: 24)
            findPrevButton.frame = NSRect(x: 272, y: 5, width: 26, height: 24)
            findNextButton.frame = NSRect(x: 300, y: 5, width: 26, height: 24)
            findCount.frame = NSRect(x: 334, y: 9, width: 200, height: 16)
            findDoneButton.frame = NSRect(x: b.width - 78, y: 5, width: 64, height: 24)
        }
    }

    func windowDidResize(_ notification: Notification) { layoutChrome() }

    func windowDidBecomeKey(_ notification: Notification) {
        activeTab?.lastActive = Date()
        Downloads.shared.statusHandler = { [weak self] msg in self?.showStatus(msg) }
    }

    func windowWillClose(_ notification: Notification) {
        saveSessionNow()
        hibernationTimer?.invalidate()
        memoryTimer?.invalidate()
        memoryPressureSource?.cancel()
        AppDelegate.shared?.windowClosed(self)
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(url: url, isPrivate: isPrivateWindow, delegate: self, configuration: configuration)
        tabs.append(tab)
        // An opener-created tab must have its web view before we return it to WebKit.
        if configuration != nil { tab.ensureLoaded() }
        if activate {
            activeIndex = tabs.count - 1
            attachActiveTab()
            if url == nil { focusURLField() }
        }
        refreshChrome()
        scheduleSessionSave()
        return tab
    }

    func restore(saved: [SavedTab], activeIndex idx: Int) {
        for s in saved {
            let t = Tab(saved: s, delegate: self)
            tabs.append(t)
        }
        activeIndex = min(max(0, idx), max(0, tabs.count - 1))
        attachActiveTab()
        refreshChrome()
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func selectRelativeTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        selectTab(index: ((activeIndex + delta) % n + n) % n)
    }

    func closeTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if tab.url != nil, !isPrivateWindow {
            closedTabs.append(tab.snapshot())
            if closedTabs.count > 10 { closedTabs.removeFirst() }
        }
        tab.webView?.removeFromSuperview()
        tab.hibernate()
        tabs.remove(at: index)
        if tabs.isEmpty {
            saveSessionNow()
            window?.close()
            return
        }
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if index < activeIndex { activeIndex -= 1 }
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    func closeActiveTab() { closeTab(index: activeIndex) }

    /// Restores the last closed tab with its history and scroll position intact.
    @objc func reopenClosedTab() {
        guard let saved = closedTabs.popLast() else {
            showStatus("No recently closed tabs")
            return
        }
        let tab = Tab(saved: saved, delegate: self)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        attachActiveTab()
        refreshChrome()
        scheduleSessionSave()
    }

    /// Swap the visible web view. Waking a hibernated tab happens here.
    private func attachActiveTab() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = activeTab else { return }
        tab.lastActive = Date()

        if tab.url == nil && !tab.hasEverLoaded {
            startView.rebuild()
            startView.frame = webContainer.bounds
            webContainer.addSubview(startView)
            return
        }
        let wv = tab.ensureLoaded()
        wv.frame = webContainer.bounds
        webContainer.addSubview(wv)
        window?.makeFirstResponder(wv)
    }

    private func focusWebContent() {
        if let wv = activeTab?.webView { window?.makeFirstResponder(wv) }
    }

    func focusURLField() {
        window?.makeFirstResponder(urlField)
    }

    // MARK: - Chrome refresh

    @objc private func newTabFromToolbar() { newTab() }

    func refreshChrome() {
        layoutChrome()
        tabStrip.update(tabs: tabs, selected: activeIndex)

        guard let tab = activeTab else { return }
        // ToolbarButton handles its own enabled/disabled tinting.
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward

        reloadButton.setSymbol(tab.isLoading ? "xmark" : "arrow.clockwise")
        reloadButton.toolTip = tab.isLoading ? "Stop loading" : "Reload (\u{2318}R)"
        progressBar.active = tab.isLoading && tab.progress < 1
        progressBar.progress = tab.progress

        if window?.firstResponder !== urlField.currentEditor() {
            let text = tab.url.map { u -> String in
                let s = u.absoluteString
                return s == "about:blank" ? "" : Store.displayForm(s)
            } ?? ""
            if urlField.stringValue != text { urlField.stringValue = text }
        }

        urlBar.showSecurity(for: tab.url)
        let bookmarked = tab.url.map { Store.shared.isBookmarked($0) } ?? false
        bookmarkButton.setSymbol(bookmarked ? "star.fill" : "star")
        bookmarkButton.isHighlighted2 = bookmarked
        bookmarkButton.isEnabled = tab.url != nil

        let blocking = Config.shared.blockAdsAndTrackers && ContentBlocker.ruleList != nil
        shieldButton.isHighlighted2 = blocking
        shieldButton.setSymbol(blocking ? "shield.lefthalf.filled" : "shield.slash")
        shieldButton.toolTip = blocking
            ? "Blocking \(ContentBlocker.ruleCount) ad & tracker rules \u{2014} click to disable"
            : "Ad & tracker blocking off \u{2014} click to enable"

        window?.title = tab.displayTitle
    }

    // MARK: - Actions

    @objc func goBack() { activeTab?.goBack() }
    @objc func goForward() { activeTab?.goForward() }

    @objc func reloadOrStop() {
        guard let tab = activeTab else { return }
        tab.isLoading ? tab.stop() : tab.reload()
    }

    @objc func reload() { activeTab?.reload() }

    @objc func stopLoading() {
        guard let tab = activeTab, tab.isLoading else { return }
        tab.stop()
        refreshChrome()
    }

    @objc func toggleBlocking() {
        Config.shared.blockAdsAndTrackers.toggle()
        Config.shared.save()
        if Config.shared.blockAdsAndTrackers {
            ContentBlocker.load { [weak self] _ in
                self?.reloadAllForRuleChange()
            }
        } else {
            reloadAllForRuleChange()
        }
    }

    private func reloadAllForRuleChange() {
        // Content rules are baked into a configuration at creation time, so tabs must
        // be rebuilt. Hibernating them does exactly that, for free.
        for (i, tab) in tabs.enumerated() where i != activeIndex { tab.hibernate() }
        if let tab = activeTab {
            tab.webView?.removeFromSuperview()
            tab.hibernate()
            attachActiveTab()
        }
        refreshChrome()
        showStatus(Config.shared.blockAdsAndTrackers ? "Blocking on" : "Blocking off")
    }

    @objc func toggleBookmark() {
        guard let tab = activeTab, let u = tab.url else { return }
        let added = Store.shared.toggleBookmark(url: u, title: tab.title)
        showStatus(added ? "Bookmarked" : "Bookmark removed")
        refreshChrome()
        AppDelegate.shared?.rebuildBookmarksMenu()
    }

    @objc private func urlFieldCommitted() {
        let raw = urlField.stringValue
        guard let url = Config.shared.resolve(input: raw) else { return }
        if activeTab == nil { newTab(url: url); return }
        activeTab?.load(url)
        attachActiveTab()
        refreshChrome()
        focusWebContent()
        scheduleSessionSave()
    }

    @objc func zoomIn() { adjustZoom(1.1) }
    @objc func zoomOut() { adjustZoom(1 / 1.1) }
    @objc func zoomReset() { activeTab?.webView?.pageZoom = 1 }

    private func adjustZoom(_ factor: CGFloat) {
        guard let wv = activeTab?.webView else { return }
        wv.pageZoom = min(3, max(0.4, wv.pageZoom * factor))
        showStatus("Zoom \(Int(wv.pageZoom * 100))%")
    }

    // MARK: - Find

    @objc func showFindBar() {
        findVisible = true
        layoutChrome()
        window?.makeFirstResponder(findField)
    }

    @objc func hideFindBar() {
        findVisible = false
        findCount.stringValue = ""
        layoutChrome()
        focusWebContent()
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    private func runFind(backwards: Bool) {
        guard let wv = activeTab?.webView, !findField.stringValue.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(findField.stringValue, configuration: cfg) { [weak self] result in
            self?.findCount.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    // MARK: - Hibernation

    private func startHibernationTimer() {
        hibernationTimer?.invalidate()
        guard Config.shared.hibernateAfterMinutes > 0 else { return }
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.hibernateIdleTabs()
        }
    }

    private func hibernateIdleTabs() {
        let threshold = Config.shared.hibernateAfterMinutes * 60
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if tab.canHibernate(idleFor: threshold) { tab.hibernate(); slept += 1 }
        }
        if slept > 0 {
            refreshChrome()
            saveSessionNow()
        }
    }

    /// Menu action: put every background tab to sleep right now.
    @objc func hibernateBackgroundTabsNow() {
        var slept = 0
        for (i, tab) in tabs.enumerated() where i != activeIndex {
            if !tab.isHibernated { tab.hibernate(); slept += 1 }
        }
        refreshChrome()
        showStatus(slept == 0 ? "Nothing to sleep" : "Slept \(slept) tab\(slept == 1 ? "" : "s")")
    }

    private func installMemoryPressureHandling() {
        guard Config.shared.hibernateOnMemoryPressure else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("Lantern: memory pressure, sleeping background tabs")
            self.hibernateBackgroundTabsNow()
            URLCache.shared.removeAllCachedResponses()
        }
        src.resume()
        memoryPressureSource = src
    }

    // MARK: - Memory readout

    private func startMemoryReadout() {
        guard Config.shared.showMemoryReadout else { return }
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self, let w = self.window,
                  w.isVisible, w.occlusionState.contains(.visible) else { return }
            self.updateMemoryReadout()
        }
    }

    private func updateMemoryReadout() {
        guard statusResetWork == nil else { return }   // a transient message is showing
        let s = MemoryMonitor.sample()
        let sleeping = tabs.filter { $0.isHibernated }.count
        var text = s.display
        if sleeping > 0 { text += " \u{00B7} \(sleeping) asleep" }
        statusPill.text = text
        statusPill.toolTip = "\(s.display) total \u{2014} app \(ByteCountFormatter.string(fromByteCount: Int64(s.appBytes), countStyle: .memory)) + \(s.helperCount) web process\(s.helperCount == 1 ? "" : "es")"
        layoutChrome()
    }

    func showStatus(_ message: String) {
        statusResetWork?.cancel()
        statusPill.text = message
        layoutChrome()
        let work = DispatchWorkItem { [weak self] in
            self?.statusResetWork = nil
            self?.updateMemoryReadout()
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Session

    private func scheduleSessionSave() {
        guard !isPrivateWindow, !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sessionSaveScheduled = false
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        guard !isPrivateWindow else { return }
        let snapshots = tabs.filter { $0.url != nil }.map { $0.snapshot() }
        Store.shared.saveSession(snapshots, activeIndex: activeIndex)
        Store.shared.flush()
    }
}

// MARK: - Delegates

extension BrowserWindowController: TabDelegate {
    func tabDidChangeState(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        if idx == activeIndex {
            refreshChrome()
        } else {
            tabStrip.update(tabs: tabs, selected: activeIndex)
        }
        if !tab.isLoading { scheduleSessionSave() }
    }

    func tab(_ tab: Tab, openNewTabWith url: URL?, configuration: WKWebViewConfiguration?, activate: Bool) -> Tab? {
        let previous = activeIndex
        let newOne = newTab(url: url, activate: true, configuration: configuration)
        if !activate, tabs.indices.contains(previous) {
            activeIndex = previous
            attachActiveTab()
            refreshChrome()
        }
        return newOne
    }

    func tabRequestsClose(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(index: idx)
    }

    func tabStatus(_ tab: Tab, message: String?) {
        if let message { showStatus(message) }
    }
}

extension BrowserWindowController: TabStripDelegate {
    func tabStripDidSelect(index: Int) { selectTab(index: index) }
    func tabStripDidRequestClose(index: Int) { closeTab(index: index) }
    func tabStripDidRequestNewTab() { newTab() }

    func tabStripDidRequestMove(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        // Keep the selection on the same tab, not the same slot.
        if activeIndex == from {
            activeIndex = to
        } else if from < activeIndex, to >= activeIndex {
            activeIndex -= 1
        } else if from > activeIndex, to <= activeIndex {
            activeIndex += 1
        }
        refreshChrome()
        scheduleSessionSave()
    }

    /// Handlers capture the Tab itself, not its index, so a menu left open while tabs
    /// move around cannot act on the wrong one.
    func tabStripContextActions(index: Int) -> [(String, () -> Void)] {
        guard tabs.indices.contains(index) else { return [] }
        let tab = tabs[index]
        var items: [(String, () -> Void)] = []

        items.append(("Reload", { [weak self] in
            tab.reload(); self?.refreshChrome()
        }))
        items.append(("Duplicate Tab", { [weak self] in
            guard let self, let u = tab.url else { return }
            self.newTab(url: u)
        }))
        if let u = tab.url {
            items.append(("Copy Address", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }))
        }
        items.append(("-", {}))
        if !tab.isHibernated {
            items.append(("Put Tab to Sleep", { [weak self] in
                guard let self else { return }
                // Never tear down the tab currently on screen.
                if tab === self.activeTab { self.showStatus("Can\u{2019}t sleep the active tab"); return }
                tab.hibernate()
                self.refreshChrome()
            }))
        }
        items.append(("-", {}))
        items.append(("Close Tab", { [weak self] in
            guard let self, let i = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(index: i)
        }))
        if tabs.count > 1 {
            items.append(("Close Other Tabs", { [weak self] in
                guard let self else { return }
                for other in self.tabs where other !== tab {
                    if let u = other.url { self.closedTabs.append(other.snapshot()); _ = u }
                    other.webView?.removeFromSuperview()
                    other.hibernate()
                }
                self.tabs = [tab]
                self.activeIndex = 0
                self.attachActiveTab()
                self.refreshChrome()
                self.scheduleSessionSave()
            }))
        }
        return items
    }
}

extension BrowserWindowController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === urlField { urlBar.setFocused(true) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === urlField { urlBar.setFocused(false) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField, !suppressCompletion,
              let editor = urlField.currentEditor() as? NSTextView else { return }
        suppressCompletion = true
        editor.complete(nil)
        suppressCompletion = false
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1     // do not auto-insert; let the user arrow down
        return Store.shared.suggestions(for: textView.string)
    }
}
