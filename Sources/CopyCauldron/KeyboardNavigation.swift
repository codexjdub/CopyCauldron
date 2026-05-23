import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Shared keyboard-navigation primitives for the list-of-clipboard-items
/// views (`PanelView`, `QuickSwitcherView`). Two related concerns live
/// here so the bugs we've already paid for don't recur:
///
/// 1. **Local NSEvent monitor lifecycle + window scoping.**
///    `NSEvent.addLocalMonitorForEvents` is application-wide; without a
///    scope guard, the main panel's monitor fires for HUD keypresses and
///    consumes them before the HUD's own monitor runs. The
///    `windowScopedKeyMonitor` view modifier owns the monitor handle, the
///    `WindowAccessor` bridge, and the `event.window === hostingWindow`
///    check in one place.
///
/// 2. **`kVK_ANSI_1`–`kVK_ANSI_9` digit detection.**
///    `event.charactersIgnoringModifiers` has a documented Shift carve-out
///    — Shift+1 reports "!" on a US layout, so `Int(chars)` returns nil
///    and Shift+digit silently no-ops. `Keyboard.digitIndex(for:)` keys
///    off the raw `keyCode` instead.
///
/// Each view keeps its own `handleKey` switch because the rest of the
/// shortcut set diverges (PanelView's three-way Escape behaviour,
/// `/`-focuses-search, `p`-toggles-pin, letter pin shortcuts, search-focus
/// exclusion; QuickSwitcherView has none of those). Forcing one shape
/// over both costs more than it saves.

// MARK: – Window-scoped local key monitor

/// View modifier: installs a local `NSEvent` keyDown monitor on appear,
/// scoped to this view's hosting `NSWindow`, and tears it down on
/// disappear. The handler runs only for events targeted at this window;
/// return `true` to consume the event (the modifier returns `nil` from
/// the monitor closure), `false` to let it propagate to the focused view.
private struct WindowScopedKeyMonitor: ViewModifier {
    let handler: (NSEvent) -> Bool

    @State private var keyMonitor: Any?
    @State private var hostingWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                // Stable once set — but SwiftUI calls `updateNSView` on
                // every layout, so the guard avoids spurious writes.
                if hostingWindow !== window {
                    hostingWindow = window
                }
            })
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // App-wide monitor: also fires for events targeted at other
            // windows in this app (the other panel, the Preferences
            // window, etc.). Pass those through so their own focused
            // view / monitor handles them.
            guard let window = hostingWindow, event.window === window else {
                return event
            }
            return handler(event) ? nil : event
        }
    }

    private func remove() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

extension View {
    /// Installs a window-scoped local NSEvent keyDown monitor. See
    /// `WindowScopedKeyMonitor` for the rationale; the handler returns
    /// `true` to consume the event.
    func windowScopedKeyMonitor(
        handler: @escaping (NSEvent) -> Bool
    ) -> some View {
        modifier(WindowScopedKeyMonitor(handler: handler))
    }
}

// MARK: – Keycode helpers

enum Keyboard {
    /// Maps `kVK_ANSI_1`…`kVK_ANSI_9` to the 1-based digit they represent,
    /// or `nil` for anything else. We key off the hardware key code (not
    /// `event.charactersIgnoringModifiers`) because that property has a
    /// documented Shift carve-out: on a US layout Shift+1 reports `"!"`
    /// and `Int("!")` is nil, so Shift+digit silently no-ops.
    static func digitIndex(for event: NSEvent) -> Int? {
        digitKeyCodes[Int(event.keyCode)]
    }

    /// Maps `kVK_ANSI_A`/`S`/`D`/`F`/`G`/`H`/`J`/`K`/`L` to 1–9 in left-
    /// to-right home-row order. Quick Switcher accepts these alongside
    /// the digit row so power users don't have to leave home row to pick
    /// a recent item.
    static func homeRowIndex(for event: NSEvent) -> Int? {
        homeRowKeyCodes[Int(event.keyCode)]
    }

    /// Either a digit (1–9) or a home-row letter (a/s/d/f/g/h/j/k/l) →
    /// the 1-based position it represents. Used by Quick Switcher so the
    /// same handler treats both inputs identically.
    static func shortcutIndex(for event: NSEvent) -> Int? {
        digitIndex(for: event) ?? homeRowIndex(for: event)
    }

    /// Home-row letter shown next to the digit in shortcut badges,
    /// indexed 1–9. Returns `nil` for out-of-range indices.
    static func homeRowLabel(forIndex index: Int) -> String? {
        guard index >= 1 && index <= homeRowLetters.count else { return nil }
        return homeRowLetters[index - 1]
    }

    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3,
        kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6,
        kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    private static let homeRowKeyCodes: [Int: Int] = [
        kVK_ANSI_A: 1, kVK_ANSI_S: 2, kVK_ANSI_D: 3,
        kVK_ANSI_F: 4, kVK_ANSI_G: 5, kVK_ANSI_H: 6,
        kVK_ANSI_J: 7, kVK_ANSI_K: 8, kVK_ANSI_L: 9,
    ]

    private static let homeRowLetters: [String] = [
        "a", "s", "d", "f", "g", "h", "j", "k", "l",
    ]
}

// MARK: – Selection movement

enum Selection {
    /// Returns the ID of the row `delta` steps from `current` in `items`,
    /// clamped to the array bounds. Used for arrow-key list navigation.
    /// When `current` is `nil` or not found, treats it as "before the
    /// first row" so ↓ selects the first item.
    static func adjacentID<Item: Identifiable>(
        in items: [Item],
        from current: Item.ID?,
        by delta: Int
    ) -> Item.ID? {
        guard !items.isEmpty else { return nil }
        let currentIdx: Int
        if let current, let i = items.firstIndex(where: { $0.id == current }) {
            currentIdx = i
        } else {
            currentIdx = -1
        }
        let newIdx = max(0, min(items.count - 1, currentIdx + delta))
        return items[newIdx].id
    }
}
