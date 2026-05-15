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
    private var hoverView: StatusItemHoverView?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private let hoverOpenDelay: TimeInterval = 0.3
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var frontmostAppObserver: NSObjectProtocol?
    private var previousFrontmostApp: NSRunningApplication?
    private let panelOpenedSubject = PassthroughSubject<Void, Never>()
    private lazy var preferencesController = PreferencesWindowController(
        preferences: preferences
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.maxPinnedItems = preferences.maxPinnedItems
        store.maxHistoryItems = preferences.maxHistoryItems
        maxPinnedSink = preferences.$maxPinnedItems
            .sink { [weak self] new in
                self?.store.maxPinnedItems = new
            }
        maxHistorySink = preferences.$maxHistoryItems
            .sink { [weak self] new in
                self?.store.maxHistoryItems = new
            }
        setUpStatusItem()
        setUpPanel()
        setUpFrontmostAppTracking()
        monitor.start()
        setUpHotKey()
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
        closePanel(respectingPin: true)
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
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Preferences.minPanelSize
        panel.maxSize = Preferences.maxPanelSize
        panel.setContentSize(initialSize)
        let hostingController = NSHostingController(
            rootView: PanelView(
                store: store,
                preferences: preferences,
                onCopy: { [weak self] item, invertPlain in
                    self?.activate(item, invertPlainText: invertPlain)
                },
                onPreferences: { [weak self] in
                    self?.closePanel(respectingPin: true)
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

    private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
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

        // Backup closers — the panel's transient-like dismiss isn't always reliable.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel(respectingPin: true)
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel(respectingPin: true)
            }
        }
    }

    private func closePanel(respectingPin: Bool = false) {
        guard !(respectingPin && preferences.keepPanelOpen) else { return }
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let obs = resignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            resignActiveObserver = nil
        }
        if panel.isVisible {
            preferences.panelOrigin = panel.frame.origin
        }
        panel.orderOut(nil)
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
        if preferences.keepPanelOpen {
            preferences.panelOrigin = panel.frame.origin
        } else {
            closePanel()
        }
        copyToPasteboard(item, plainTextOnly: plainText)
        if preferences.autoPaste {
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
                    self?.pasteWhenFrontmost(prev)
                }
            } else {
                Paster.pasteAfterDelay()
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
    /// then posts the synthetic ⌘V immediately.
    private func pasteWhenFrontmost(_ target: NSRunningApplication,
                                    deadline: Date = Date().addingTimeInterval(0.4)) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == target.bundleIdentifier
            || Date() >= deadline {
            Paster.pasteAfterDelay(0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.pasteWhenFrontmost(target, deadline: deadline)
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
