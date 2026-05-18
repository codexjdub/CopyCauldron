import SwiftUI
import AppKit
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
    private let hotKeyManager = HotKeyManager()

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
        let plainText = preferences.pastePlainTextOnly != invertPlainText
        let prev = previousFrontmostApp
        // Panel stays open in both pin states now. When pin is off the
        // target app's activation below brings it forward over the panel;
        // when pin is on the panel keeps floating above.
        preferences.panelOrigin = panel.frame.origin
        copyToPasteboard(item, plainTextOnly: plainText)
        if preferences.autoPaste {
            // Fresh token per activate() — any older paste chain in flight
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
        monitor.suppressNext = true
        store.copyToPasteboard(item, plainTextOnly: plainTextOnly)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.monitor.resetBaseline()
        }
    }
}
