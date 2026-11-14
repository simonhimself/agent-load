import AppKit
import SwiftUI
import ServiceManagement
import AgentLoadCore

/// Borderless panel that can take key focus (needed for hover tracking and closing on
/// click-outside via resignKey) without showing a title bar.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }   // Esc closes
    /// ⌘Q quits while the dropdown is open (the app has no main menu as a menu-bar-only app).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
            NSApp.terminate(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The menu bar app.
///
/// Approach: a plain `NSStatusItem` + our own `NSPanel`s instead of SwiftUI `MenuBarExtra`:
/// - MenuBarExtra renders its label as a monochrome template, so the dot could not be coloured;
///   an NSStatusItem button with a non-template image keeps the real green/amber/red.
/// - The hover side panel is a second borderless window placed next to the dropdown, which
///   MenuBarExtra's window style gives no handle for.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Where the hover side panel goes. The mockup draws it to the RIGHT of the dropdown.
    /// The dropdown hangs below the status item near the right screen edge, so usually there
    /// is no room on the right; then it flips to the left. (One-line switch; open decision.)
    enum HoverSide { case rightIfRoomElseLeft, alwaysLeft }
    static let hoverSide: HoverSide = .rightIfRoomElseLeft

    static let openInterval: TimeInterval = 3      // refresh while the dropdown is open
    static let closedInterval: TimeInterval = 10   // refresh while closed (icon only)

    private let model = AppModel()
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "agentload.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sampling = false

    private var statusItem: NSStatusItem!
    private var panel: KeyPanel!
    private var sidePanel: NSPanel!
    private var sideHost: NSHostingView<AnyView>!
    private var clickMonitor: Any?
    /// Newest snapshot; given to the views only while the dropdown is open.
    private var latest: Snapshot?
    private var lastStatus: (StatusLevel, Int?)?
    private var isOpen: Bool { panel?.isVisible == true }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(togglePanel)
            b.imagePosition = .imageLeading
        }
        updateStatusItem(level: .green, count: nil)
        makePanels()

        model.onHoverChange = { [weak self] _ in self?.updateSidePanel() }
        model.onOpenFolder = { [weak self] row in
            guard !row.folderPath.isEmpty else { return }
            self?.closePanel()
            // Reveal (select) the folder in Finder. Finder opens it; this app reads nothing there.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.folderPath)])
        }
        model.onQuit = { NSApp.terminate(nil) }
        model.onMore = { [weak self] in self?.showMoreMenu() }

        refresh()
        schedule(interval: Self.closedInterval)

        // Diagnostics for verification (see README): print the status item's screen frame,
        // optionally open the dropdown and hover the first session row.
        if CommandLine.arguments.contains("--debug") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let w = self.statusItem.button?.window else { return }
                print("STATUS_ITEM_FRAME \(Int(w.frame.minX)) \(Int(w.frame.minY)) \(Int(w.frame.width)) \(Int(w.frame.height)) screenHeight \(Int(w.screen?.frame.height ?? 0))")
                fflush(stdout)
            }
        }
        if CommandLine.arguments.contains("--debug-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.openPanel()
                if CommandLine.arguments.contains("--debug-hover") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard let self, let first = self.model.snapshot?.sessions.first else { return }
                        self.model.hoveredRowID = first.id
                        self.updateSidePanel()
                    }
                }
            }
        }
    }

    // MARK: Status item

    /// Coloured dot (non-template image, so macOS keeps the colour) + session count.
    private func updateStatusItem(level: StatusLevel, count: Int?) {
        guard let b = statusItem.button else { return }
        if let last = lastStatus, last.0 == level, last.1 == count { return }
        lastStatus = (level, count)
        let color: NSColor
        switch level {
        case .green: color = NSColor(srgbRed: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0, alpha: 1)
        case .amber: color = NSColor(srgbRed: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0, alpha: 1)
        case .red: color = NSColor(srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
        }
        // 8 pt dot as in the mockup; AppKit adds the gap between image and title.
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        img.isTemplate = false
        b.image = img
        b.title = count.map(String.init) ?? "–"
        b.toolTip = "Agent Load"
    }

    // MARK: Panels

    private func makePanels() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.closePanel() }
        let host = NSHostingView(rootView: DropdownView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.closePanel()
        }

        sidePanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        sidePanel.isOpaque = false
        sidePanel.backgroundColor = .clear
        sidePanel.hasShadow = true
        sidePanel.level = .popUpMenu
        sidePanel.ignoresMouseEvents = true      // purely informational; never steals the hover
        sidePanel.isReleasedWhenClosed = false
        sideHost = NSHostingView(rootView: AnyView(EmptyView()))
        sidePanel.contentView = sideHost
    }

    @objc private func togglePanel() {
        isOpen ? closePanel() : openPanel()
    }

    private func openPanel() {
        if let latest { model.snapshot = latest }
        layoutPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        refresh()
        schedule(interval: Self.openInterval)
    }

    private func closePanel() {
        guard isOpen else { return }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        model.hoveredRowID = nil
        updateSidePanel()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        schedule(interval: Self.closedInterval)
    }

    /// Sizes the dropdown to its SwiftUI content and hangs it below the status item.
    private func layoutPanel() {
        guard let host = panel.contentView, let itemWin = statusItem.button?.window,
              let screen = itemWin.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        let vis = screen.visibleFrame
        var x = itemWin.frame.minX
        x = min(x, vis.maxX - size.width - 4)
        x = max(x, vis.minX + 4)
        let top = itemWin.frame.minY - 3
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Shows/hides/positions the hover side panel for the hovered session row.
    private func updateSidePanel() {
        guard isOpen, let id = model.hoveredRowID, let snap = model.snapshot,
              let content = Self.sidePanel(for: id, in: snap),
              let rowFrame = model.rowFrames[id] else {
            if sidePanel.isVisible { panel.removeChildWindow(sidePanel); sidePanel.orderOut(nil) }
            return
        }
        sideHost.rootView = AnyView(content)
        let size = sideHost.fittingSize
        let vis = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let gap: CGFloat = 6
        var x = panel.frame.maxX + gap
        if Self.hoverSide == .alwaysLeft || x + size.width > vis.maxX {
            x = panel.frame.minX - gap - size.width
        }
        // Top of the side panel level with the top of the hovered row.
        var top = panel.frame.maxY - rowFrame.minY
        top = max(top, vis.minY + size.height)
        sidePanel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        if !sidePanel.isVisible {
            panel.addChildWindow(sidePanel, ordered: .above)
            sidePanel.orderFront(nil)
        }
    }

    /// Hands a snapshot to the dropdown and re-places the windows.
    private func publish(_ snap: Snapshot) {
        model.snapshot = snap
        if let id = model.hoveredRowID, Self.sidePanel(for: id, in: snap) == nil {
            model.hoveredRowID = nil
        }
        // Let SwiftUI lay out the new rows first, then resize and re-place.
        DispatchQueue.main.async {
            self.layoutPanel()
            self.updateSidePanel()
        }
    }

    /// Side panel for a hovered row: a session, or one of the two folded groups.
    static func sidePanel(for id: String, in snap: Snapshot) -> SidePanelView? {
        if let row = snap.sessions.first(where: { $0.id == id }) { return SidePanelView(row: row) }
        for g in [snap.agentToolsGroup, snap.otherAppsGroup] where g.id == id { return SidePanelView(group: g) }
        return nil
    }

    // MARK: Refresh

    private func schedule(interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    /// Samples on a background queue (DB lookups for new shells can take a moment) and
    /// publishes on the main thread.
    private func refresh() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            guard let self else { return }
            // Other users' processes (Spotlight) via one `ps` call: always included so the
            // numbers are already warm when the dropdown opens.
            let snap = self.sampler.sample(includeOtherUsers: true)
            DispatchQueue.main.async {
                self.sampling = false
                self.latest = snap
                self.updateStatusItem(level: snap.level, count: snap.sessionCount)
                // While closed only the icon changes: pushing data into the hidden SwiftUI view
                // would re-render it for nothing (that was most of the app's CPU use).
                if self.isOpen { self.publish(snap) }
            }
        }
    }

    // MARK: - "…" menu

    /// Native menu at the mouse: "Open at Login" (checkmark = registered) and "Quit ⌘Q".
    /// Open at Login uses SMAppService.mainApp, so it registers whichever copy is running
    /// (normally /Applications/Agent Load.app).
    private func showMoreMenu() {
        let menu = NSMenu()
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("AgentLoad: Open at Login failed: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
