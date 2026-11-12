import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var controllers: [BrowserWindowController] = []
    /// URLs can arrive from LaunchServices before the first window exists (clicking a
    /// link while Lantern is closed), so hold them until the window is up.
    private var isReady = false
    private var pendingURLs: [URL] = []
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let historyMenu = NSMenu(title: "History")

    var front: BrowserWindowController? {
        if let w = NSApp.keyWindow?.windowController as? BrowserWindowController { return w }
        if let w = NSApp.mainWindow?.windowController as? BrowserWindowController { return w }
        return controllers.last
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Compile the blocklist before the first web view exists: content rules are
        // attached at configuration time, so getting this in first avoids a reload.
        ContentBlocker.load { [weak self] _ in
            self?.openInitialWindow()
        }
    }

    private func openInitialWindow() {
        let c = makeWindow()
        let session = Store.shared.loadSession()
        if Config.shared.restoreSessionOnLaunch, !session.tabs.isEmpty {
            c.restore(saved: session.tabs, activeIndex: session.activeIndex)
            let sleeping = max(0, session.tabs.count - 1)
            if sleeping > 0 {
                c.showStatus("Restored \(session.tabs.count) tabs, \(sleeping) asleep")
            }
        }
        if !pendingURLs.isEmpty {
            // Open every URL, but focus the first, like Safari and Chrome do. Focusing
            // the last would leave whichever page happened to be at the end of the list
            // running in the foreground.
            let firstNew = c.tabs.count
            for u in pendingURLs {
                let tab = c.newTab(url: u, activate: false)
                tab.ensureLoaded()   // explicitly requested by the user, so load it now
            }
            pendingURLs.removeAll()
            c.selectTab(index: firstNew)
        } else if c.tabs.isEmpty {
            c.newTab()
        }
        isReady = true
        rebuildBookmarksMenu()
    }

    @discardableResult
    private func makeWindow(isPrivate: Bool = false) -> BrowserWindowController {
        let c = BrowserWindowController(isPrivate: isPrivate)
        controllers.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        if controllers.count > 1, let w = c.window {
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x + 24, y: w.frame.origin.y - 24))
        }
        return c
    }

    func windowClosed(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controllers.forEach { $0.saveSessionNow() }
        Store.shared.flush()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow().newTab() }
        return true
    }

    /// Links opened from other apps (and from being the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else { pendingURLs.append(contentsOf: urls); return }
        let c = front ?? makeWindow()
        for u in urls { c.newTab(url: u) }
        c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu actions

    @objc func newTab() { (front ?? makeWindow()).newTab() }
    @objc func newWindow() { makeWindow().newTab() }
    @objc func newPrivateWindow() { makeWindow(isPrivate: true).newTab() }
    @objc func closeTab() { front?.closeActiveTab() }
    @objc func reopenClosedTab() { front?.reopenClosedTab() }
    @objc func focusAddressBar() { front?.focusURLField() }
    @objc func reload() { front?.reload() }
    @objc func stopLoading() { front?.stopLoading() }
    @objc func goBack() { front?.goBack() }
    @objc func goForward() { front?.goForward() }
    @objc func find() { front?.showFindBar() }
    @objc func findNext() { front?.findNext() }
    @objc func findPrevious() { front?.findPrevious() }
    @objc func bookmark() { front?.toggleBookmark() }
    @objc func zoomIn() { front?.zoomIn() }
    @objc func zoomOut() { front?.zoomOut() }
    @objc func zoomReset() { front?.zoomReset() }
    @objc func sleepBackgroundTabs() { front?.hibernateBackgroundTabsNow() }
    @objc func nextTab() { front?.selectRelativeTab(1) }
    @objc func previousTab() { front?.selectRelativeTab(-1) }
    @objc func openDownloadsFolder() { Downloads.shared.revealFolder() }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let c = front else { return }
        let n = sender.tag
        c.selectTab(index: n == 9 ? max(0, c.tabs.count - 1) : n)
    }

    @objc func openSettings() {
        Config.shared.save()
        NSWorkspace.shared.open(Config.supportDir.appendingPathComponent("config.json"))
    }

    @objc func openBlocklist() {
        if let u = ContentBlocker.domainListURL() { NSWorkspace.shared.open(u) }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let u = URL(string: sender.representedObject as? String ?? "") else { return }
        (front ?? makeWindow()).newTab(url: u)
    }

    @objc func clearHistory() {
        let a = NSAlert()
        a.messageText = "Clear browsing history?"
        a.informativeText = "Bookmarks and cookies are kept."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearHistory()
        rebuildHistoryMenu()
        front?.showStatus("History cleared")
    }

    @objc func clearWebsiteData() {
        let a = NSAlert()
        a.messageText = "Clear cookies and cached data?"
        a.informativeText = "You will be signed out of websites."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            URLCache.shared.removeAllCachedResponses()
            self?.front?.showStatus("Website data cleared")
        }
    }

    @objc func makeDefaultBrowser() {
        guard let me = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { [weak self] err in
            DispatchQueue.main.async {
                if let err {
                    self?.front?.showStatus("Couldn\u{2019}t set default: \(err.localizedDescription)")
                } else {
                    NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { _ in }
                    self?.front?.showStatus("Lantern is now the default browser")
                }
            }
        }
    }

    @objc func showAbout() {
        let s = MemoryMonitor.sample()
        let a = NSAlert()
        a.messageText = "Lantern 🏮"
        a.informativeText = """
        A minimal browser on the system WebKit engine.

        Right now: \(s.display) across \(s.helperCount + 1) process\(s.helperCount == 0 ? "" : "es").
        Blocking \(ContentBlocker.ruleCount) ad and tracker rules.
        Background tabs sleep after \(Int(Config.shared.hibernateAfterMinutes)) min.
        """
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: - Menu construction

    func rebuildBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        let add = NSMenuItem(title: "Bookmark This Page", action: #selector(bookmark), keyEquivalent: "d")
        add.target = self
        bookmarksMenu.addItem(add)
        bookmarksMenu.addItem(.separator())
        if Store.shared.bookmarks.isEmpty {
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            bookmarksMenu.addItem(empty)
        }
        for b in Store.shared.bookmarks {
            let title = b.title.isEmpty ? Store.displayForm(b.url) : b.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = b.url
            bookmarksMenu.addItem(item)
        }
    }

    func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            historyMenu.addItem(i)
        }
        add("Back", #selector(goBack), "[")
        add("Forward", #selector(goForward), "]")
        historyMenu.addItem(.separator())
        for e in Store.shared.recentHistory(limit: 15) {
            let title = e.title.isEmpty ? Store.displayForm(e.url) : e.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.url
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        add("Clear History\u{2026}", #selector(clearHistory), "")
        add("Clear Cookies and Cache\u{2026}", #selector(clearWebsiteData), "")
    }

    private func buildMenu() {
        let main = NSMenu()

        func menu(_ title: String) -> (NSMenuItem, NSMenu) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return (item, m)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            m.addItem(i)
        }

        // App menu
        let (_, app) = menu("Lantern 🏮")
        add(app, "About Lantern 🏮", #selector(showAbout), target: self)
        app.addItem(.separator())
        add(app, "Settings\u{2026}", #selector(openSettings), ",", target: self)
        add(app, "Edit Blocklist\u{2026}", #selector(openBlocklist), target: self)
        add(app, "Make Lantern the Default Browser", #selector(makeDefaultBrowser), target: self)
        app.addItem(.separator())
        add(app, "Hide Lantern", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Lantern", #selector(NSApplication.terminate(_:)), "q")

        // File
        let (_, file) = menu("File")
        add(file, "New Tab", #selector(newTab), "t", target: self)
        add(file, "New Window", #selector(newWindow), "n", target: self)
        add(file, "New Private Window", #selector(newPrivateWindow), "n", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Open Location\u{2026}", #selector(focusAddressBar), "l", target: self)
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeTab), "w", target: self)
        add(file, "Reopen Closed Tab", #selector(reopenClosedTab), "t", [.command, .shift], target: self)
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        file.addItem(.separator())
        add(file, "Open Downloads Folder", #selector(openDownloadsFolder), "j", [.command, .shift], target: self)

        // Edit  (standard responder selectors: required for text editing inside pages)
        let (_, edit) = menu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find\u{2026}", #selector(find), "f", target: self)
        add(edit, "Find Next", #selector(findNext), "g", target: self)
        add(edit, "Find Previous", #selector(findPrevious), "g", [.command, .shift], target: self)

        // View
        let (_, view) = menu("View")
        add(view, "Reload Page", #selector(reload), "r", target: self)
        add(view, "Stop", #selector(stopLoading), ".", target: self)
        view.addItem(.separator())
        add(view, "Actual Size", #selector(zoomReset), "0", target: self)
        add(view, "Zoom In", #selector(zoomIn), "+", target: self)
        add(view, "Zoom Out", #selector(zoomOut), "-", target: self)
        view.addItem(.separator())
        add(view, "Sleep Background Tabs Now", #selector(sleepBackgroundTabs), "h", [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // History
        let (historyItem, _) = menu("History")
        historyItem.submenu = historyMenu
        historyMenu.delegate = self
        rebuildHistoryMenu()

        // Bookmarks
        let (bmItem, _) = menu("Bookmarks")
        bmItem.submenu = bookmarksMenu

        // Window
        let (windowItem, windowMenu) = menu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "Show Next Tab", #selector(nextTab), "\u{0009}", [.control], target: self)
        add(windowMenu, "Show Previous Tab", #selector(previousTab), "\u{0009}", [.control, .shift], target: self)
        // Arrow variants: the shortcut most people reach for first.
        add(windowMenu, "Next Tab (arrow)", #selector(nextTab), "\u{F703}", [.command, .option], target: self)
        add(windowMenu, "Previous Tab (arrow)", #selector(previousTab), "\u{F702}", [.command, .option], target: self)
        windowMenu.addItem(.separator())
        for n in 1...9 {
            add(windowMenu, "Tab \(n)", #selector(selectTabByNumber(_:)), "\(n)", target: self, tag: n - 1)
        }
        windowMenu.addItem(.separator())
        add(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu
        _ = windowItem

        NSApp.mainMenu = main
    }

    /// Refresh the history submenu lazily when it is opened, not on every page load.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu { rebuildHistoryMenu() }
    }
}
