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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = ClipboardStore()
    let preferences = Preferences()
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private let hotKeyManager = HotKeyManager()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKeySink: AnyCancellable?
    private var maxPinnedSink: AnyCancellable?
    private var maxHistorySink: AnyCancellable?
    private var hoverView: StatusItemHoverView?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private let hoverOpenDelay: TimeInterval = 0.3
    private var outsideClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var previousFrontmostApp: NSRunningApplication?
    private let popoverOpenedSubject = PassthroughSubject<Void, Never>()
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
        setUpPopover()
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
        togglePopover()
    }

    // MARK: – Hover-to-open

    private func handleMouseEntered() {
        guard preferences.openOnHover else { return }
        guard !popover.isShown else { return }
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
            guard !self.popover.isShown else { return }
            self.togglePopover()
        }
        hoverOpenWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: work)
    }

    private func cancelPendingHoverOpen() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
    }

    // MARK: – Popover

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let initialSize = preferences.popoverSize
        popover.contentSize = initialSize
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                onCopy: { [weak self] item, invertPlain in
                    self?.activate(item, invertPlainText: invertPlain)
                },
                onQuit: { NSApp.terminate(nil) },
                onPreferences: { [weak self] in
                    self?.closePopover()
                    self?.openPreferences()
                },
                onClose: { [weak self] in
                    self?.closePopover()
                },
                initialSize: initialSize,
                onResize: { [weak self] newSize in
                    self?.popover.contentSize = newSize
                },
                onResizeEnd: { [weak self] finalSize in
                    self?.preferences.popoverSize = finalSize
                },
                popoverOpened: popoverOpenedSubject.eraseToAnyPublisher()
            )
        )
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // Remember which app was frontmost so we can restore focus before pasting.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverOpenedSubject.send()
        // Strip the auto-assigned first responder so the search field isn't
        // focused on open — that way 1–9 paste pinned items immediately.
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }

        // Backup closers — NSPopover's .transient isn't always reliable.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let obs = resignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            resignActiveObserver = nil
        }
        popover.performClose(nil)
    }

    // MARK: – Hotkey

    private func setUpHotKey() {
        hotKeyManager.onPress = { [weak self] in
            self?.togglePopover()
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

    /// Activate an item: close popover, copy to pasteboard, and (if enabled)
    /// auto-paste into the previously active app. When `invertPlainText` is
    /// true (e.g. the user held Shift) the effective plain-text mode is
    /// flipped for this paste only.
    private func activate(_ item: ClipboardItem, invertPlainText: Bool = false) {
        let plainText = preferences.pastePlainTextOnly != invertPlainText
        let prev = previousFrontmostApp
        closePopover()
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
    /// then posts the synthetic ⌘V. We wait an additional settle delay after
    /// the target becomes frontmost because the app-frontmost state doesn't
    /// guarantee its key window is ready to receive synthesized key events.
    private func pasteWhenFrontmost(_ target: NSRunningApplication,
                                    deadline: Date = Date().addingTimeInterval(0.4)) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == target.bundleIdentifier
            || Date() >= deadline {
            Paster.pasteAfterDelay(0.15)
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
