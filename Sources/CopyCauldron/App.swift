import SwiftUI
import AppKit
import ApplicationServices
import Combine

@main
struct CopyCauldronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one Scene; we manage the preferences window
        // manually via NSWindowController so it works reliably for LSUIElement.
        Settings { EmptyView() }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate {
    let store = ClipboardStore()
    let preferences = Preferences()
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private let hotKeyManager = HotKeyManager(id: 1)
    private let quickSwitcherHotKeyManager = HotKeyManager(id: 2)

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hotKeySink: AnyCancellable?
    private var maxPinnedSink: AnyCancellable?
    private var maxHistorySink: AnyCancellable?
    private var retentionSink: AnyCancellable?
    private var keepPanelOpenSink: AnyCancellable?
    private var hoverView: StatusItemHoverView?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private let hoverOpenDelay: TimeInterval = 0.3
    private var frontmostAppObserver: NSObjectProtocol?
    private var previousFrontmostApp: NSRunningApplication?
    /// Identifies the currently-active paste flow. A fresh value is generated
    /// each time `activate(_:invertPlainText:)` schedules a paste; the
    /// `pasteWhenFrontmost` recursion bails out the moment it sees a token
    /// other than its own. Coalesces back-to-back item activations so we
    /// don't fire ⌘V twice when the user rapidly picks two items.
    private var currentPasteFlightToken: UUID?
    private let panelOpenedSubject = PassthroughSubject<Void, Never>()

    // MARK: – Quick switcher state
    private var quickSwitcherPanel: FloatingPanel!
    private var quickSwitcherOutsideClickMonitor: Any?
    private var quickSwitcherHotKeySink: AnyCancellable?
    private lazy var preferencesController = PreferencesWindowController(
        preferences: preferences
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.maxPinnedItems = preferences.maxPinnedItems
        store.maxHistoryItems = preferences.maxHistoryItems
        store.retentionPeriod = preferences.retentionPeriod
        maxPinnedSink = preferences.$maxPinnedItems
            .sink { [weak self] new in
                self?.store.maxPinnedItems = new
            }
        maxHistorySink = preferences.$maxHistoryItems
            .sink { [weak self] new in
                self?.store.maxHistoryItems = new
            }
        retentionSink = preferences.$retentionPeriod
            .sink { [weak self] new in
                self?.store.retentionPeriod = new
            }
        setUpStatusItem()
        setUpPanel()
        setUpFrontmostAppTracking()
        monitor.start()
        setUpHotKey()
        // Re-apply pin state whenever the user toggles it via the chrome.
        // `dropFirst()` skips the initial emission — `setUpPanel` already
        // applied the persisted value once during creation.
        keepPanelOpenSink = preferences.$keepPanelOpen
            .dropFirst()
            .sink { [weak self] pinned in
                self?.applyPinState(pinned)
            }
        setUpQuickSwitcherPanel()
        setUpQuickSwitcherHotKey()
    }

    // MARK: – Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeStatusItemImage()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let view = StatusItemHoverView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.onMouseEntered = { [weak self] in self?.handleMouseEntered() }
            view.onMouseExited  = { [weak self] in self?.handleMouseExited()  }
            button.addSubview(view)
            hoverView = view
        }
    }

    private func makeStatusItemImage() -> NSImage? {
        let image = makeBundledStatusItemImage() ?? NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "CopyCauldron"
        )
        image?.isTemplate = true
        image?.size = NSSize(width: 22, height: 22)
        return image
    }

    private func makeBundledStatusItemImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        for resource in [
            "MenuBarIconTemplate",
            "MenuBarIconTemplate@2x",
            "MenuBarIconTemplate@3x"
        ] {
            guard
                let url = Bundle.main.url(forResource: resource, withExtension: "png"),
                let data = try? Data(contentsOf: url),
                let representation = NSBitmapImageRep(data: data)
            else {
                continue
            }
            representation.size = NSSize(width: 22, height: 22)
            image.addRepresentation(representation)
        }
        return image.representations.isEmpty ? nil : image
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        // A click should win over a pending hover-open and just toggle.
        cancelPendingHoverOpen()
        if shouldShowStatusMenu(for: NSApp.currentEvent) {
            showStatusMenu()
            return
        }
        togglePanel()
    }

    private func shouldShowStatusMenu(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Preferences...",
            action: #selector(statusMenuPreferences),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit CopyCauldron",
            action: #selector(statusMenuQuit),
            keyEquivalent: "q"
        ).target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func statusMenuPreferences() {
        openPreferences()
    }

    @objc private func statusMenuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: – Hover-to-open

    private func handleMouseEntered() {
        guard preferences.openOnHover else { return }
        guard !panel.isVisible else { return }
        scheduleHoverOpen()
    }

    private func handleMouseExited() {
        cancelPendingHoverOpen()
    }

    private func scheduleHoverOpen() {
        cancelPendingHoverOpen()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.preferences.openOnHover else { return }
            guard !self.panel.isVisible else { return }
            self.togglePanel()
        }
        hoverOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: work)
    }

    private func cancelPendingHoverOpen() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
    }

    // MARK: – Panel

    private func setUpPanel() {
        let initialSize = preferences.panelSize

        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Preferences.minPanelSize
        panel.maxSize = Preferences.maxPanelSize
        panel.setContentSize(initialSize)
        // Pin state determines whether we float above other windows or sit at
        // normal level (where the user can click another window and have it
        // come forward over us). Applied here and again from
        // `keepPanelOpenSink` when the user toggles the chrome's pin button.
        applyPinState(preferences.keepPanelOpen)
        let hostingController = NSHostingController(
            rootView: PanelView(
                store: store,
                preferences: preferences,
                onCopy: { [weak self] item, invertPlain in
                    self?.activate(item, invertPlainText: invertPlain)
                },
                onPreferences: { [weak self] in
                    // Panel never auto-closes in the new behavior — leave
                    // it open and just bring Preferences forward.
                    self?.openPreferences()
                },
                onClose: { [weak self] in
                    self?.closePanel()
                },
                onCopyPathAsText: { [weak self] urls in
                    self?.copyPathsToPasteboard(urls)
                },
                initialSize: initialSize,
                panelOpened: panelOpenedSubject.eraseToAnyPublisher()
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
    }

    private func setUpFrontmostAppTracking() {
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                self?.rememberExternalFrontmostApp(app)
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberExternalFrontmostApp(frontmost)
        }
    }

    private func rememberExternalFrontmostApp(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousFrontmostApp = app
    }

    /// Three-state toggle: hidden → show; visible-but-behind → raise; visible
    /// and key → close. Used by the menu-bar icon and the global hotkey.
    private func togglePanel() {
        // Dismiss the HUD as a courtesy — if the user is reaching for the
        // main panel, the transient overlay shouldn't linger on top of it.
        closeQuickSwitcher()
        if !panel.isVisible {
            showPanel()
        } else if !panel.isKeyWindow {
            // Panel is on screen but another window came forward; the user
            // is asking for it back, so raise and key it.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            closePanel()
        }
    }

    private func showPanel() {
        guard statusItem.button != nil else { return }
        // Remember which app was frontmost so we can restore focus before pasting.
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberExternalFrontmostApp(frontmost)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(preferredPanelFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        panelOpenedSubject.send()
        // Strip the auto-assigned first responder so the search field isn't
        // focused on open — that way 1–9 paste pinned items immediately.
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(nil)
        }
        // No outside-click or resign-active dismissal: the panel persists
        // until Esc / close button / menu-bar toggle. When pin is off the
        // panel naturally goes behind whatever the user clicks on next.
    }

    private func closePanel() {
        if panel.isVisible {
            preferences.panelOrigin = panel.frame.origin
        }
        panel.orderOut(nil)
    }

    /// Applies the pin state to the panel: `true` → floating above other
    /// windows; `false` → normal-level window that yields to other apps.
    /// Safe to call multiple times — both properties are idempotent.
    private func applyPinState(_ pinned: Bool) {
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
    }

    private func preferredPanelFrame() -> NSRect {
        let size = preferences.panelSize
        if let origin = preferences.panelOrigin {
            return clampedPanelFrame(NSRect(origin: origin, size: size))
        }
        return defaultPanelFrame(size: size)
    }

    private func defaultPanelFrame(size: CGSize) -> NSRect {
        guard let button = statusItem.button,
              let window = button.window else {
            return clampedPanelFrame(NSRect(origin: .zero, size: size))
        }

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? screen(containing: buttonFrame) ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)
        let x = clamped(
            buttonFrame.midX - size.width / 2,
            lower: visible.minX,
            upper: max(visible.minX, visible.maxX - size.width)
        )
        let y = clamped(
            buttonFrame.minY - size.height - 6,
            lower: visible.minY,
            upper: max(visible.minY, visible.maxY - size.height)
        )
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func clampedPanelFrame(_ frame: NSRect) -> NSRect {
        guard let screen = screen(containing: frame) ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = clamped(
            frame.minX,
            lower: visible.minX,
            upper: max(visible.minX, visible.maxX - width)
        )
        let y = clamped(
            frame.minY,
            lower: visible.minY,
            upper: max(visible.minY, visible.maxY - height)
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              panel.isVisible else { return }
        preferences.panelOrigin = panel.frame.origin
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              panel.isVisible else { return }
        preferences.panelSize = panel.frame.size
        preferences.panelOrigin = panel.frame.origin
    }

    // MARK: – Hotkey

    private func setUpHotKey() {
        hotKeyManager.onPress = { [weak self] in
            self?.togglePanel()
        }
        hotKeyManager.register(preferences.hotKey)
        // Re-register whenever the user picks a new combo.
        hotKeySink = preferences.$hotKey
            .dropFirst()
            .sink { [weak self] newKey in
                self?.hotKeyManager.register(newKey)
            }
    }

    // MARK: – Preferences window

    private func openPreferences() {
        preferencesController.show()
    }

    // MARK: – Activation (click / number key)

    /// Activate an item: close the panel, copy to pasteboard, and (if enabled)
    /// auto-paste into the previously active app. When `invertPlainText` is
    /// true (e.g. the user held Shift) the effective plain-text mode is
    /// flipped for this paste only.
    private func activate(_ item: ClipboardItem, invertPlainText: Bool = false) {
        // Main-panel activation: save the panel origin so we restore the
        // same position next time. The quick switcher uses `performPaste`
        // directly since it doesn't own a draggable panel.
        // Panel stays open in both pin states now. When pin is off the
        // target app's activation below brings it forward over the panel;
        // when pin is on the panel keeps floating above.
        preferences.panelOrigin = panel.frame.origin
        performPaste(item, invertPlainText: invertPlainText)
    }

    /// Shared paste flow used by both the main panel and the quick switcher
    /// HUD. Copies the item to the system pasteboard and, when auto-paste
    /// is enabled, hands activation to the previous app and posts ⌘V.
    private func performPaste(_ item: ClipboardItem, invertPlainText: Bool = false) {
        let plainText = preferences.pastePlainTextOnly != invertPlainText
        let prev = previousFrontmostApp
        copyToPasteboard(item, plainTextOnly: plainText)
        if preferences.autoPaste {
            // Fresh token per paste — any older paste chain in flight
            // sees a mismatch on its next tick and abandons itself, so two
            // rapid item picks coalesce into a single ⌘V on the latest one.
            let token = UUID()
            currentPasteFlightToken = token
            if let prev {
                // macOS 14+ cooperative activation: yield our activation rights
                // so the target app can activate over us.
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: prev)
                }
                prev.activate()
                // If the user held a modifier (e.g. Shift for the plain-text
                // override), it leaks through CGEvent at the HID level and
                // changes ⌘V into ⌘⇧V. Wait until they release before pasting.
                waitForShiftRelease { [weak self] in
                    self?.pasteWhenFrontmost(prev, token: token)
                }
            } else {
                // No known target — schedule a fallback paste guarded by the
                // same token so a rapid follow-up activate can supersede it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.currentPasteFlightToken == token else { return }
                    self.currentPasteFlightToken = nil
                    Paster.pasteAfterDelay(0)
                }
            }
        }
    }

    private func waitForShiftRelease(timeout: TimeInterval = 1.0,
                                     completion: @escaping () -> Void) {
        if !NSEvent.modifierFlags.contains(.shift) {
            completion()
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if !NSEvent.modifierFlags.contains(.shift) || Date() >= deadline {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check() }
        }
        check()
    }

    /// Waits until `target` is reported as frontmost (or a 400ms timeout),
    /// then posts the synthetic ⌘V immediately. The `token` is checked on
    /// each iteration so an older chain bails as soon as a newer
    /// `activate()` installs a fresh token.
    private func pasteWhenFrontmost(_ target: NSRunningApplication,
                                    token: UUID,
                                    deadline: Date = Date().addingTimeInterval(0.4)) {
        // A newer activate() has taken over — abandon this chain.
        guard currentPasteFlightToken == token else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == target.bundleIdentifier
            || Date() >= deadline {
            // Pasting now. Clear the token before scheduling so anything that
            // still holds a stale copy will guard out.
            currentPasteFlightToken = nil
            Paster.pasteAfterDelay(0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.pasteWhenFrontmost(target, token: token, deadline: deadline)
        }
    }

    private func copyToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool) {
        store.copyToPasteboard(item, plainTextOnly: plainTextOnly)
        monitor.suppressCurrentChangeCount()
    }

    private func copyPathsToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        monitor.suppressCurrentChangeCount()
    }

    // MARK: – Quick switcher (HUD)

    private func setUpQuickSwitcherPanel() {
        // Fixed width; height grows with the user's chosen row count.
        let initialSize = NSSize(
            width: Self.quickSwitcherWidth,
            height: Self.quickSwitcherHeight(forRowCount: preferences.quickSwitcherItemCount)
        )
        quickSwitcherPanel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        quickSwitcherPanel.isFloatingPanel = true
        quickSwitcherPanel.level = .floating
        quickSwitcherPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        quickSwitcherPanel.hidesOnDeactivate = false
        quickSwitcherPanel.isReleasedWhenClosed = false
        // NSPanel defaults `becomesKeyOnlyIfNeeded` to true, which means the
        // panel only becomes key when something inside it "needs" keyboard
        // input (e.g. a TextField). Our HUD is all Buttons, so without this
        // override the panel never becomes key, the local NSEvent monitor
        // never fires, and digit shortcuts silently no-op.
        quickSwitcherPanel.becomesKeyOnlyIfNeeded = false
        quickSwitcherPanel.isOpaque = false
        quickSwitcherPanel.backgroundColor = .clear
        quickSwitcherPanel.hasShadow = true

        let hostingController = NSHostingController(
            rootView: QuickSwitcherView(
                store: store,
                preferences: preferences,
                onActivate: { [weak self] item, shiftHeld in
                    self?.activateFromQuickSwitcher(item, invertPlainText: shiftHeld)
                },
                onClose: { [weak self] in
                    self?.closeQuickSwitcher()
                }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        quickSwitcherPanel.contentViewController = hostingController
    }

    private static let quickSwitcherWidth: CGFloat = 320

    /// Empirically-derived height that fits the row layout in
    /// `QuickSwitcherView`: ~32pt per row plus 2pt inter-row spacing plus
    /// 24pt of chrome (outer padding + rounded border).
    private static func quickSwitcherHeight(forRowCount count: Int) -> CGFloat {
        let chrome: CGFloat = 24
        let perRow: CGFloat = 32
        let spacing: CGFloat = max(0, CGFloat(count - 1)) * 2
        return chrome + perRow * CGFloat(count) + spacing
    }

    private func setUpQuickSwitcherHotKey() {
        quickSwitcherHotKeyManager.onPress = { [weak self] in
            self?.toggleQuickSwitcher()
        }
        quickSwitcherHotKeyManager.register(preferences.quickSwitcherHotKey)
        quickSwitcherHotKeySink = preferences.$quickSwitcherHotKey
            .dropFirst()
            .sink { [weak self] newKey in
                self?.quickSwitcherHotKeyManager.register(newKey)
            }
    }

    private func toggleQuickSwitcher() {
        if quickSwitcherPanel.isVisible {
            closeQuickSwitcher()
        } else {
            showQuickSwitcher()
        }
    }

    private func showQuickSwitcher() {
        // Track the previously-active app so paste targets the right place,
        // same pattern as the main panel.
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberExternalFrontmostApp(frontmost)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Resize before show in case the user changed the row count via
        // Preferences while the HUD was hidden.
        let size = NSSize(
            width: Self.quickSwitcherWidth,
            height: Self.quickSwitcherHeight(forRowCount: preferences.quickSwitcherItemCount)
        )
        quickSwitcherPanel.setContentSize(size)
        // Try the Accessibility-based path first: anchor the HUD to the
        // text insertion point in the previously-active app. Fall back to
        // the mouse cursor when AX isn't available or the focused element
        // doesn't expose a usable range (web fields, terminals, etc.).
        let origin: NSPoint
        if let prev = previousFrontmostApp,
           let caret = textInsertionRect(for: prev) {
            origin = quickSwitcherOrigin(anchoredBelow: caret, size: size)
        } else {
            origin = clampedQuickSwitcherOrigin(near: NSEvent.mouseLocation, size: size)
        }
        quickSwitcherPanel.setFrameOrigin(origin)
        quickSwitcherPanel.makeKeyAndOrderFront(nil)

        // Transient — outside-click dismisses. The main panel persists,
        // but the HUD is meant to be momentary.
        quickSwitcherOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closeQuickSwitcher()
            }
        }
    }

    private func closeQuickSwitcher() {
        if let m = quickSwitcherOutsideClickMonitor {
            NSEvent.removeMonitor(m)
            quickSwitcherOutsideClickMonitor = nil
        }
        // `?.` because togglePanel calls this courtesy-close, which could
        // fire before applicationDidFinishLaunching wires up the panel
        // (it doesn't in practice, but harmless to guard).
        quickSwitcherPanel?.orderOut(nil)
    }

    /// Queries the Accessibility API for the screen-space bounds of the
    /// text insertion point in the focused element of `app`. Returns `nil`
    /// when AX isn't trusted, the app doesn't expose a focused element, or
    /// the focused element isn't a text-bearing control. Callers should
    /// fall back to mouse-cursor positioning on nil.
    ///
    /// Coordinates are returned in NSScreen-style (bottom-left origin); AX
    /// reports top-left origin, so we flip relative to the primary screen.
    private func textInsertionRect(for app: NSRunningApplication) -> CGRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Cap how long we'll wait on any single AX call so a hung target
        // app can't freeze the HUD's appearance.
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focused = focusedRaw else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = focused as! AXUIElement

        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeValue = rangeRaw else { return nil }

        var boundsRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRaw
        ) == .success, let boundsValue = boundsRaw else { return nil }

        guard CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        let axValue = boundsValue as! AXValue
        var axRect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &axRect),
              axRect.height > 0 else { return nil }

        // AX is top-left-origin in the global coordinate space of the
        // primary screen; NSWindow is bottom-left-origin.
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - axRect.origin.y - axRect.height
        return CGRect(
            x: axRect.origin.x,
            y: flippedY,
            width: axRect.width,
            height: axRect.height
        )
    }

    /// Places the HUD just below the caret rect, anchored to its left
    /// edge. Flips above the caret if there isn't room below, and clamps
    /// to the screen's visible frame in both axes.
    private func quickSwitcherOrigin(anchoredBelow caret: CGRect,
                                     size: CGSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)

        var x = caret.minX
        // "Below the caret" in bottom-left coords = smaller Y. Place the
        // HUD's top edge a few pt below the caret bottom.
        var y = caret.minY - 6 - size.height

        // Not enough room below → flip above (HUD's bottom edge just over
        // the caret top).
        if y < visible.minY {
            y = caret.maxY + 6
        }

        if x < visible.minX { x = visible.minX }
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if y + size.height > visible.maxY { y = visible.maxY - size.height }
        if y < visible.minY { y = visible.minY }
        return NSPoint(x: x, y: y)
    }

    /// Positions the HUD so the cursor sits ~10pt inside the top edge,
    /// horizontally centered on the cursor, clamped to the cursor's screen.
    private func clampedQuickSwitcherOrigin(near mouseLocation: NSPoint,
                                            size: CGSize) -> NSPoint {
        var x = mouseLocation.x - size.width / 2
        var topY = mouseLocation.y - 10
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)
        if x < visible.minX { x = visible.minX }
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if topY > visible.maxY { topY = visible.maxY }
        if topY - size.height < visible.minY { topY = visible.minY + size.height }
        // NSWindow origin is bottom-left, so convert top → bottom-left.
        return NSPoint(x: x, y: topY - size.height)
    }

    private func activateFromQuickSwitcher(_ item: ClipboardItem,
                                           invertPlainText: Bool = false) {
        closeQuickSwitcher()
        performPaste(item, invertPlainText: invertPlainText)
    }
}
