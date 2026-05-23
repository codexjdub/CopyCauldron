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

/// Coordinator for the two panel surfaces and the shared services that
/// outlive any single window: clipboard store, preferences, clipboard
/// monitor, status item, frontmost-app tracking, and the paste
/// pipeline. The panels themselves live in `MainPanelController` and
/// `QuickSwitcherController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = ClipboardStore()
    let preferences = Preferences()
    private(set) lazy var monitor = ClipboardMonitor(
        store: store,
        preferences: preferences
    )

    private var statusItem: NSStatusItem!
    private var hoverView: StatusItemHoverView?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private let hoverOpenDelay: TimeInterval = 0.3

    private var frontmostAppObserver: NSObjectProtocol?
    private var previousFrontmostApp: NSRunningApplication?

    /// Identifies the currently-active paste flow. A fresh value is
    /// generated each time `performPaste` schedules one; the
    /// `pasteWhenFrontmost` recursion bails out the moment it sees a
    /// token other than its own. Coalesces back-to-back item
    /// activations so we don't fire ⌘V twice when the user rapidly
    /// picks two items.
    private var currentPasteFlightToken: UUID?

    private var maxPinnedSink: AnyCancellable?
    private var maxHistorySink: AnyCancellable?
    private var retentionSink: AnyCancellable?

    private var mainPanel: MainPanelController!
    private var quickSwitcher: QuickSwitcherController!
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
        setUpFrontmostAppTracking()
        monitor.start()
        setUpControllers()
    }

    // MARK: – Controllers

    private func setUpControllers() {
        // Order matters only because `MainPanelController.onBeforeShow`
        // captures the Quick Switcher — Swift's two-phase init lets us
        // create either first, but constructing the Quick Switcher
        // first keeps the wiring readable: HUD exists by the time the
        // courtesy-close closure is set.
        quickSwitcher = QuickSwitcherController(
            store: store,
            preferences: preferences,
            frontmostAppProvider: { [weak self] in
                self?.previousFrontmostApp
            },
            onActivate: { [weak self] item, invert in
                self?.performPaste(item, invertPlainText: invert)
            }
        )
        mainPanel = MainPanelController(
            store: store,
            preferences: preferences,
            statusItemButtonProvider: { [weak self] in
                self?.statusItem.button
            },
            onActivate: { [weak self] item, invert in
                self?.performPaste(item, invertPlainText: invert)
            },
            onPreferences: { [weak self] in
                self?.openPreferences()
            },
            onCopyPathAsText: { [weak self] urls in
                self?.copyPathsToPasteboard(urls)
            }
        )
        // Courtesy: dismiss the HUD when the main panel is about to
        // take focus. The reverse (close main panel when HUD opens)
        // isn't symmetric — the main panel is persistent and the HUD
        // is transient.
        mainPanel.onBeforeShow = { [weak self] in
            self?.quickSwitcher.close()
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
        mainPanel.toggle()
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
        guard !mainPanel.isVisible else { return }
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
            guard !self.mainPanel.isVisible else { return }
            self.mainPanel.toggle()
        }
        hoverOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: work)
    }

    private func cancelPendingHoverOpen() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
    }

    // MARK: – Frontmost-app tracking

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

    // MARK: – Preferences window

    private func openPreferences() {
        preferencesController.show()
    }

    // MARK: – Paste pipeline

    /// Shared paste flow used by both the main panel and the quick
    /// switcher HUD. Copies the item to the system pasteboard and,
    /// when auto-paste is enabled, hands activation to the previous
    /// app and posts ⌘V.
    private func performPaste(_ item: ClipboardItem, invertPlainText: Bool = false) {
        let plainText = preferences.pastePlainTextOnly != invertPlainText
        let prev = previousFrontmostApp
        copyToPasteboard(item, plainTextOnly: plainText)
        if preferences.autoPaste {
            // Fresh token per paste — any older paste chain in flight
            // sees a mismatch on its next tick and abandons itself, so
            // two rapid item picks coalesce into a single ⌘V on the
            // latest one.
            let token = UUID()
            currentPasteFlightToken = token
            if let prev {
                // macOS 14+ cooperative activation: yield our
                // activation rights so the target app can activate
                // over us.
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: prev)
                }
                prev.activate()
                // If the user held a modifier (e.g. Shift for the
                // plain-text override), it leaks through CGEvent at
                // the HID level and changes ⌘V into ⌘⇧V. Wait until
                // they release before pasting.
                waitForShiftRelease { [weak self] in
                    self?.pasteWhenFrontmost(prev, token: token)
                }
            } else {
                // No known target — schedule a fallback paste guarded
                // by the same token so a rapid follow-up activate can
                // supersede it.
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

    /// Waits until `target` is reported as frontmost (or a 400ms
    /// timeout), then posts the synthetic ⌘V immediately. The `token`
    /// is checked on each iteration so an older chain bails as soon as
    /// a newer `performPaste()` installs a fresh token.
    private func pasteWhenFrontmost(_ target: NSRunningApplication,
                                    token: UUID,
                                    deadline: Date = Date().addingTimeInterval(0.4)) {
        // A newer performPaste() has taken over — abandon this chain.
        guard currentPasteFlightToken == token else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == target.bundleIdentifier
            || Date() >= deadline {
            // Pasting now. Clear the token before scheduling so
            // anything that still holds a stale copy will guard out.
            currentPasteFlightToken = nil
            Paster.pasteAfterDelay(0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.pasteWhenFrontmost(target, token: token, deadline: deadline)
        }
    }

    private func copyToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool) {
        writeToPasteboard {
            store.copyToPasteboard(item, plainTextOnly: plainTextOnly)
        }
    }

    private func copyPathsToPasteboard(_ urls: [URL]) {
        writeToPasteboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    private func writeToPasteboard(_ write: () -> Void) {
        write()
        monitor.suppressCurrentChangeCount()
    }
}
