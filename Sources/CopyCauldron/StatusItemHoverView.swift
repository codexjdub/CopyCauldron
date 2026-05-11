import AppKit

/// A transparent overlay added inside the status item button so we can detect
/// hover events. NSStatusBarButton swallows mouseEntered/Exited when delivered
/// to a non-NSResponder owner, so we use an NSView subclass instead.
@MainActor
final class StatusItemHoverView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    // Don't intercept clicks — let them pass through to the underlying button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
