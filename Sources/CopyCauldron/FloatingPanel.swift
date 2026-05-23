import AppKit

/// `NSPanel` subclass used by both the main panel and the Quick Switcher
/// HUD. Default `NSPanel` returns `false` from `canBecomeKey` /
/// `canBecomeMain`, which prevents the panel from taking focus — the
/// local NSEvent monitors inside our SwiftUI views never fire, and
/// keyboard shortcuts silently no-op. Overriding both to `true` makes
/// the panel behave like a regular borderless window for keyboard
/// purposes while keeping the panel-level conveniences (collection
/// behavior, hides-on-deactivate flag, etc.).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
