import SwiftUI
import AppKit
import ApplicationServices
import Combine

/// Owns everything tied to the Quick Switcher HUD: its floating panel,
/// its global hotkey, the outside-click monitor, and the AX-based caret
/// positioning. Created by `AppDelegate` and wired up via two callbacks:
///
/// - `frontmostAppProvider` reads the most-recent external frontmost
///   app from `AppDelegate` so the AX caret query targets the right
///   process.
/// - `onActivate` is the paste pipeline — fires after the controller
///   has closed the HUD.
///
/// The HUD lives at `.floating` level, is `becomesKeyOnlyIfNeeded =
/// false` (a Button-only view tree won't otherwise become key, and the
/// local NSEvent monitor in `QuickSwitcherView` would never fire), and
/// dismisses on any outside click via a global event monitor.
@MainActor
final class QuickSwitcherController {
    private let store: ClipboardStore
    private let preferences: Preferences
    private let frontmostAppProvider: () -> NSRunningApplication?
    private let onActivate: (ClipboardItem, Bool) -> Void

    private let hotKeyManager = HotKeyManager(id: 2)
    private var panel: FloatingPanel!
    private var hotKeySink: AnyCancellable?
    private var outsideClickMonitor: Any?

    init(
        store: ClipboardStore,
        preferences: Preferences,
        frontmostAppProvider: @escaping () -> NSRunningApplication?,
        onActivate: @escaping (ClipboardItem, Bool) -> Void
    ) {
        self.store = store
        self.preferences = preferences
        self.frontmostAppProvider = frontmostAppProvider
        self.onActivate = onActivate
        setUpPanel()
        setUpHotKey()
    }

    // MARK: – Public API

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            show()
        }
    }

    /// Idempotent. Also tears down the outside-click monitor. Safe to
    /// call from `MainPanelController`'s courtesy-close hook even
    /// before this controller has been fully initialized — the panel
    /// optional guard handles that edge.
    func close() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    // MARK: – Setup

    private func setUpPanel() {
        // Fixed width; height grows with the user's chosen row count.
        let initialSize = NSSize(
            width: Self.width,
            height: Self.height(forRowCount: preferences.quickSwitcherItemCount)
        )
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // NSPanel defaults `becomesKeyOnlyIfNeeded` to true, which means
        // the panel only becomes key when something inside it "needs"
        // keyboard input (e.g. a TextField). Our HUD is all Buttons, so
        // without this override the panel never becomes key, the local
        // NSEvent monitor never fires, and digit shortcuts silently
        // no-op.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hostingController = NSHostingController(
            rootView: QuickSwitcherView(
                store: store,
                preferences: preferences,
                onActivate: { [weak self] item, shiftHeld in
                    self?.activate(item, invertPlainText: shiftHeld)
                },
                onClose: { [weak self] in
                    self?.close()
                }
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
        hotKeyManager.register(preferences.quickSwitcherHotKey)
        hotKeySink = preferences.$quickSwitcherHotKey
            .dropFirst()
            .sink { [weak self] newKey in
                self?.hotKeyManager.register(newKey)
            }
    }

    // MARK: – Show / activate

    private func show() {
        NSApp.activate(ignoringOtherApps: true)

        // Resize before show in case the user changed the row count via
        // Preferences while the HUD was hidden.
        let size = NSSize(
            width: Self.width,
            height: Self.height(forRowCount: preferences.quickSwitcherItemCount)
        )
        panel.setContentSize(size)
        // Try the Accessibility-based path first: anchor the HUD to the
        // text insertion point in the previously-active app. Fall back
        // to the mouse cursor when AX isn't available or the focused
        // element doesn't expose a usable range (web fields, terminals,
        // etc.).
        let origin: NSPoint
        if let prev = frontmostAppProvider(),
           let caret = textInsertionRect(for: prev) {
            origin = quickSwitcherOrigin(anchoredBelow: caret, size: size)
        } else {
            origin = clampedQuickSwitcherOrigin(near: NSEvent.mouseLocation, size: size)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)

        // Transient — outside-click dismisses. The main panel persists,
        // but the HUD is meant to be momentary.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        }
    }

    private func activate(_ item: ClipboardItem, invertPlainText: Bool) {
        close()
        onActivate(item, invertPlainText)
    }

    // MARK: – Sizing

    private static let width: CGFloat = 320

    /// Empirically-derived height that fits the row layout in
    /// `QuickSwitcherView`: ~32pt per row plus 2pt inter-row spacing
    /// plus 24pt of chrome (outer padding + rounded border).
    private static func height(forRowCount count: Int) -> CGFloat {
        let chrome: CGFloat = 24
        let perRow: CGFloat = 32
        let spacing: CGFloat = max(0, CGFloat(count - 1)) * 2
        return chrome + perRow * CGFloat(count) + spacing
    }

    // MARK: – AX caret positioning

    /// Queries the Accessibility API for the screen-space bounds of the
    /// text insertion point in the focused element of `app`. Returns
    /// `nil` when AX isn't trusted, the app doesn't expose a focused
    /// element, or the focused element isn't a text-bearing control.
    /// Callers should fall back to mouse-cursor positioning on nil.
    ///
    /// Coordinates are returned in NSScreen-style (bottom-left origin);
    /// AX reports top-left origin, so we flip relative to the primary
    /// screen.
    private func textInsertionRect(for app: NSRunningApplication) -> CGRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Cap how long we'll wait on any single AX call so a hung
        // target app can't freeze the HUD's appearance.
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
    /// edge. Flips above the caret if there isn't room below, and
    /// clamps to the screen's visible frame in both axes.
    private func quickSwitcherOrigin(anchoredBelow caret: CGRect,
                                     size: CGSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 8)

        var x = caret.minX
        // "Below the caret" in bottom-left coords = smaller Y. Place
        // the HUD's top edge a few pt below the caret bottom.
        var y = caret.minY - 6 - size.height

        // Not enough room below → flip above (HUD's bottom edge just
        // over the caret top).
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
    /// horizontally centered on the cursor, clamped to the cursor's
    /// screen.
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
}
