import SwiftUI
import AppKit
import Combine

/// Owns the persistent main panel: the `FloatingPanel`, its global
/// hotkey, the pin-state binding, panel sizing/positioning logic, and
/// the `NSWindowDelegate` callbacks that persist drag/resize updates
/// back to `Preferences`.
///
/// Dependencies are supplied by `AppDelegate` via closures so this
/// controller can stay focused on the panel itself:
///
/// - `statusItemButtonProvider` returns the menu-bar button's bounds
///   for the "open below the status item" default position.
/// - `onActivate` runs the shared paste pipeline.
/// - `onPreferences` opens the Preferences window.
/// - `onCopyPathAsText` handles the `Copy path as text` right-click
///   action from file-URL rows.
/// - `onBeforeShow` is set post-init so AppDelegate can perform the
///   courtesy HUD close before the main panel takes focus. Fires only
///   on the "open / raise" branches of `toggle()`, not on close.
@MainActor
final class MainPanelController: NSObject, NSWindowDelegate {
    private let store: ClipboardStore
    private let preferences: Preferences
    private let statusItemButtonProvider: () -> NSStatusBarButton?
    /// Called immediately before `NSApp.activate` in `show()` so
    /// `AppDelegate` can sample `NSWorkspace.shared.frontmostApplication`
    /// and stash it as the paste target. The observer-based tracking
    /// in `AppDelegate` can race against a hotkey press, leaving
    /// `previousFrontmostApp` stale; this re-sample restores the
    /// belt-and-suspenders from the pre-extraction code.
    private let willActivate: () -> Void
    private let onActivate: (ClipboardItem, Bool) -> Void
    private let onPreferences: () -> Void
    private let onCopyPathAsText: ([URL]) -> Void

    /// Set by `AppDelegate` after both controllers exist. Fires from
    /// `toggle()` only on the open/raise branches so the courtesy HUD
    /// close doesn't run when the user is closing the main panel.
    var onBeforeShow: (() -> Void)?

    private let hotKeyManager = HotKeyManager(id: 1)
    private var panel: FloatingPanel!
    private var hotKeySink: AnyCancellable?
    private var keepPanelOpenSink: AnyCancellable?
    private let panelOpenedSubject = PassthroughSubject<Void, Never>()
    private var hoverPreview: HoverPreviewController!

    init(
        store: ClipboardStore,
        preferences: Preferences,
        statusItemButtonProvider: @escaping () -> NSStatusBarButton?,
        willActivate: @escaping () -> Void = {},
        onActivate: @escaping (ClipboardItem, Bool) -> Void,
        onPreferences: @escaping () -> Void,
        onCopyPathAsText: @escaping ([URL]) -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.statusItemButtonProvider = statusItemButtonProvider
        self.willActivate = willActivate
        self.onActivate = onActivate
        self.onPreferences = onPreferences
        self.onCopyPathAsText = onCopyPathAsText
        super.init()
        setUpPanel()
        setUpHotKey()
        setUpKeepPanelOpenSink()
        // Created after `setUpPanel()` so `panel` exists when the
        // controller's anchor closure runs. Captures `panel` via a
        // weak self-style closure so dealloc doesn't leak.
        hoverPreview = HoverPreviewController { [weak self] in
            self?.panel
        }
    }

    // MARK: – Public API

    /// Three-state toggle: hidden → show; visible-but-behind → raise;
    /// visible-and-key → close. Used by the menu-bar icon, hover-to-
    /// open, and the global hotkey.
    func toggle() {
        if !panel.isVisible {
            onBeforeShow?()
            show()
        } else if !panel.isKeyWindow {
            // Panel is on screen but another window came forward; the
            // user is asking for it back, so raise and key it.
            onBeforeShow?()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            close()
        }
    }

    func close() {
        if panel.isVisible {
            preferences.panelOrigin = panel.frame.origin
        }
        // Sidecar must follow the main panel out — otherwise the
        // preview window lingers on screen with no row to point at.
        // `forceHide` bypasses the row-leave grace period, which
        // would otherwise leave the preview on screen briefly after
        // the main panel is already gone.
        hoverPreview.forceHide()
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: – Setup

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
        // Pin state determines whether we float above other windows or
        // sit at normal level (where the user can click another window
        // and have it come forward over us). Applied here and again
        // from `keepPanelOpenSink` when the user toggles the chrome's
        // pin button.
        applyPinState(preferences.keepPanelOpen)
        let hostingController = NSHostingController(
            rootView: PanelView(
                store: store,
                preferences: preferences,
                onCopy: { [weak self] item, invertPlain in
                    self?.handleActivate(item, invertPlainText: invertPlain)
                },
                onPreferences: { [weak self] in
                    // Panel never auto-closes in the new behavior —
                    // leave it open and just bring Preferences
                    // forward.
                    self?.onPreferences()
                },
                onClose: { [weak self] in
                    self?.close()
                },
                onCopyPathAsText: { [weak self] urls in
                    self?.onCopyPathAsText(urls)
                },
                onPreviewChange: { [weak self] text, anchor in
                    self?.hoverPreview.update(text: text, anchorInPanel: anchor)
                },
                initialSize: initialSize,
                panelOpened: panelOpenedSubject.eraseToAnyPublisher()
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
    }

    private func setUpHotKey() {
        hotKeyManager.onPress = { [weak self] in
            self?.toggle()
        }
        hotKeyManager.register(preferences.hotKey)
        // Re-register whenever the user picks a new combo.
        hotKeySink = preferences.$hotKey
            .dropFirst()
            .sink { [weak self] newKey in
                self?.hotKeyManager.register(newKey)
            }
    }

    private func setUpKeepPanelOpenSink() {
        // Re-apply pin state whenever the user toggles it via the
        // chrome. `dropFirst()` skips the initial emission —
        // `setUpPanel` already applied the persisted value once during
        // creation.
        keepPanelOpenSink = preferences.$keepPanelOpen
            .dropFirst()
            .sink { [weak self] pinned in
                self?.applyPinState(pinned)
            }
    }

    // MARK: – Activation

    /// Saves the panel origin so we restore the same position next
    /// time, then hands off to the shared paste pipeline. The Quick
    /// Switcher's controller bypasses this step because it doesn't own
    /// a draggable panel.
    ///
    /// Panel stays open in both pin states now. When pin is off the
    /// target app's activation in `onActivate` brings it forward over
    /// the panel; when pin is on the panel keeps floating above.
    private func handleActivate(_ item: ClipboardItem, invertPlainText: Bool) {
        preferences.panelOrigin = panel.frame.origin
        onActivate(item, invertPlainText)
    }

    // MARK: – Pin state + positioning

    /// Applies the pin state to the panel: `true` → floating above
    /// other windows; `false` → normal-level window that yields to
    /// other apps. Safe to call multiple times — both properties are
    /// idempotent.
    private func applyPinState(_ pinned: Bool) {
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
    }

    private func show() {
        guard statusItemButtonProvider() != nil else { return }
        // Sample the current frontmost app BEFORE we activate
        // CopyCauldron — once we activate, the frontmost becomes us.
        // See `willActivate` doc for why the observer-only path isn't
        // enough here.
        willActivate()
        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(preferredPanelFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        panelOpenedSubject.send()
        // Strip the auto-assigned first responder so the search field
        // isn't focused on open — that way 1–9 paste pinned items
        // immediately.
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(nil)
        }
        // No outside-click or resign-active dismissal: the panel
        // persists until Esc / close button / menu-bar toggle. When
        // pin is off the panel naturally goes behind whatever the user
        // clicks on next.
    }

    private func preferredPanelFrame() -> NSRect {
        let size = preferences.panelSize
        if let origin = preferences.panelOrigin {
            return clampedPanelFrame(NSRect(origin: origin, size: size))
        }
        return defaultPanelFrame(size: size)
    }

    private func defaultPanelFrame(size: CGSize) -> NSRect {
        guard let button = statusItemButtonProvider(),
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

    // MARK: – NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              panel.isVisible else { return }
        preferences.panelOrigin = panel.frame.origin
        // Keep the sidecar pinned to the moving main panel.
        hoverPreview.reposition()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel,
              panel.isVisible else { return }
        preferences.panelSize = panel.frame.size
        preferences.panelOrigin = panel.frame.origin
        // Resizes change the main panel's height → recompute preview
        // vertical position too.
        hoverPreview.reposition()
    }
}
