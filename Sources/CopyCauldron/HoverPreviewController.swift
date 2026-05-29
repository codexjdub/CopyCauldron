import SwiftUI
import AppKit

/// SwiftUI preference key used by `ItemRow` to bubble its frame up to
/// `PanelView` while it's being hovered. Aggregated using "last
/// non-nil wins" semantics — at most one row is hovered at a time, so
/// the reduce just picks whichever row reports a value.
///
/// Frames are in the `panel` named coordinate space (top-left origin,
/// inside the main panel's content view). `HoverPreviewController`
/// converts panel-local → screen coords using its anchor window's
/// frame.
struct HoveredRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

/// Sidecar floating window that shows the hover-linger preview for a
/// row in the main panel. Anchored to the right edge of the main
/// panel; flips to the left edge when there isn't room on the right.
/// Never overlaps any row in the main panel, so the row's pin /
/// delete buttons stay clickable.
///
/// Owned by `MainPanelController`, which:
/// - Creates it in init with a closure that returns the main panel
///   window so we can position relative to it (or `nil` before the
///   window exists / after it's gone).
/// - Forwards the `onPreviewChange` callback from `PanelView` so the
///   SwiftUI view's existing `previewItemID` + `previewText(for:)`
///   logic still drives what's shown.
/// - Calls `update(text: nil)` when the main panel closes so the
///   sidecar disappears with it.
/// - Calls `reposition()` from `windowDidMove` so the sidecar tracks
///   the main panel as the user drags it around.
@MainActor
final class HoverPreviewController {
    private let anchor: () -> NSWindow?
    private let preferences: Preferences
    private var panel: FloatingPanel!
    private var hostingController: NSHostingController<HoverPreviewContent>!
    /// Most recently shown text. Used by `reposition()` to skip work
    /// when the panel isn't currently visible.
    private var currentText: String?
    /// Latest anchor rect from `PanelView`, in the main panel's
    /// "panel" SwiftUI coordinate space (top-left origin). Used to
    /// position the preview vertically next to the row being hovered.
    /// `nil` until the first hover.
    private var currentAnchorInPanel: CGRect?
    /// Pending "hide the preview after the row hover ended" work
    /// item. Scheduled by `update(text: nil, …)` so the user has a
    /// brief grace period to move the cursor from the row into the
    /// preview panel (where it stays until they leave it). Cancelled
    /// when a new `update(...)` arrives with non-nil text or when the
    /// preview itself starts being hovered.
    private var pendingHide: DispatchWorkItem?
    /// Grace period before a row-hover-end actually hides the
    /// preview. Long enough to span the cursor moving from the row
    /// across the gap into the preview; short enough not to feel
    /// laggy when the user moves away with no intent to scroll.
    private static let dismissDelay: TimeInterval = 0.25

    /// Base width at `medium` text size. The actual width scales
    /// with `preferences.textSize.scaleFactor` so XLarge users get a
    /// proportionally wider window instead of cramped wrapping.
    private static let baseWidth: CGFloat = 280
    /// Gap between the main panel's edge and the preview panel.
    private static let gap: CGFloat = 8

    /// Multiplier read fresh on each show/reposition so the preview
    /// stays in sync with the user's Preferences → Appearance & Startup
    /// text size choice without needing reactive subscriptions
    /// (the preview is transient — the next hover picks up new values).
    private var scaleFactor: CGFloat {
        preferences.textSize.scaleFactor
    }

    /// Scaled width used by the panel frame.
    private var width: CGFloat {
        Self.baseWidth * scaleFactor
    }

    init(anchor: @escaping () -> NSWindow?, preferences: Preferences) {
        self.anchor = anchor
        self.preferences = preferences
        setUpPanel()
    }

    // MARK: – Public API

    /// Drives visibility + content. Pass `nil` for either argument to
    /// schedule a grace-period hide (so the user can move the cursor
    /// from the row into the preview to scroll inside it).
    /// `anchorInPanel` is the hovered row's frame in `PanelView`'s
    /// named "panel" coordinate space (top-left origin) — used to
    /// align the preview vertically with the row instead of always
    /// sticking to the top of the main panel.
    func update(text: String?, anchorInPanel: CGRect?) {
        guard let text, !text.isEmpty, let anchorRect = anchorInPanel else {
            schedulePendingHide()
            return
        }
        // A row's 600ms hover-linger timer (in `ItemRow`) can fire
        // *after* the main panel has closed — AppKit doesn't reliably
        // deliver a hover-exit when a window orders out from under the
        // cursor, so the timer isn't cancelled. Never order a preview
        // front with no visible panel beside it; that would leave an
        // orphaned popup floating on screen.
        guard anchor()?.isVisible == true else {
            forceHide()
            return
        }
        // A real preview update arrived — cancel any pending hide
        // from a previous row-leave.
        pendingHide?.cancel()
        pendingHide = nil
        currentText = text
        currentAnchorInPanel = anchorRect
        hostingController.rootView = makeContent(text: text)
        reposition()
        if !panel.isVisible {
            // `orderFront`, not `makeKeyAndOrderFront` — the preview
            // never takes focus from the main panel.
            panel.orderFront(nil)
        }
    }

    /// Hides the preview immediately, bypassing the grace period.
    /// Called from `MainPanelController.close()` so the sidecar
    /// disappears with the main panel rather than lingering for the
    /// dismiss delay after the main panel is already gone.
    func forceHide() {
        pendingHide?.cancel()
        pendingHide = nil
        currentText = nil
        currentAnchorInPanel = nil
        panel.orderOut(nil)
    }

    private func schedulePendingHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.forceHide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissDelay, execute: work)
    }

    /// Hover-state callback handed to `HoverPreviewContent` so the
    /// preview can keep itself alive while the cursor is inside it.
    /// Cursor-enter cancels the pending hide; cursor-leave fires the
    /// hide immediately (the user made an explicit "I'm done" move).
    private func handlePreviewHover(isHovering: Bool) {
        if isHovering {
            pendingHide?.cancel()
            pendingHide = nil
        } else {
            forceHide()
        }
    }

    private func makeContent(text: String) -> HoverPreviewContent {
        HoverPreviewContent(
            text: text,
            textScale: scaleFactor,
            onHoverChange: { [weak self] isHovering in
                self?.handlePreviewHover(isHovering: isHovering)
            }
        )
    }

    /// Re-runs the positioning logic. Called from
    /// `MainPanelController.windowDidMove` so the preview follows the
    /// main panel as the user drags it.
    func reposition() {
        guard let text = currentText, !text.isEmpty,
              let anchorInPanel = currentAnchorInPanel,
              let main = anchor() else { return }
        panel.setFrame(
            frame(besides: main, anchorInPanel: anchorInPanel),
            display: panel.isVisible
        )
    }

    // MARK: – Setup

    private func setUpPanel() {
        hostingController = NSHostingController(rootView: makeContent(text: ""))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Default `becomesKeyOnlyIfNeeded = true` is correct here —
        // the preview has no controls and must not steal focus.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = hostingController
    }

    // MARK: – Positioning

    /// Returns the preview frame, top-aligned with the hovered row
    /// (not the top of the main panel) and horizontally placed `gap`
    /// pixels to the right of the main panel — flipping to the left
    /// when the right side doesn't have room on the main panel's
    /// screen. Vertically clamped to the screen's visible frame so it
    /// stays on screen for rows near the top or bottom edges.
    private func frame(besides main: NSWindow,
                       anchorInPanel: CGRect) -> NSRect {
        let mainFrame = main.frame
        let screen = main.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? mainFrame
        let height = fittingHeight()

        // SwiftUI's "panel" coord space has its origin at the top-left
        // of the main panel's content view; +y points down. NSWindow
        // frames are in screen coords with origin at the bottom-left;
        // +y points up. So the row's top edge in screen-Y is the main
        // panel's top edge (maxY) minus the row's top in panel-local
        // coords (minY).
        let rowTopScreenY = mainFrame.maxY - anchorInPanel.minY
        // The preview's "top" in NSWindow coords = its bottom Y + its
        // height. So if we want its top aligned to the row's top:
        var y = rowTopScreenY - height
        // Clamp to visible screen so a row near the bottom edge of the
        // main panel doesn't push the preview off the bottom of the
        // screen.
        if y < visible.minY { y = visible.minY }
        if y + height > visible.maxY { y = visible.maxY - height }

        let rightX = mainFrame.maxX + Self.gap
        // Right side fits → use it.
        if rightX + width <= visible.maxX {
            return NSRect(x: rightX, y: y, width: width, height: height)
        }
        // Else try the left.
        let leftX = mainFrame.minX - Self.gap - width
        if leftX >= visible.minX {
            return NSRect(x: leftX, y: y, width: width, height: height)
        }
        // Neither side fits — pin to the right edge of the screen and
        // accept overlap; rare on real-world screen layouts.
        return NSRect(
            x: max(visible.minX, visible.maxX - width),
            y: y,
            width: width,
            height: height
        )
    }

    /// Asks SwiftUI for the preview's intrinsic content height at the
    /// (scaled) width, capped so a huge text block doesn't grow the
    /// panel beyond the (scaled) max. Both cap and width scale with
    /// the user's text-size preference so XLarge users get a
    /// proportionally taller window.
    private func fittingHeight() -> CGFloat {
        let cap = HoverPreviewContent.baseMaxHeight * scaleFactor
        let fitting = hostingController.sizeThatFits(
            in: NSSize(width: width, height: cap)
        )
        return max(40, min(cap, fitting.height))
    }
}

/// The actual preview content. Replaces the in-panel
/// `HoverPreviewPanel` — same typography but now sized to fit a
/// fixed-width sidecar instead of stretching across the bottom of the
/// main panel.
///
/// `onHoverChange` lets the controller distinguish "cursor is over
/// the preview" from "cursor is anywhere else." When it's hovered we
/// suppress the grace-period hide so the user can scroll inside it;
/// when it's left we hide immediately.
struct HoverPreviewContent: View {
    let text: String
    /// Multiplier from `Preferences.textSize.scaleFactor`. Applied to
    /// both the body font and the inner ScrollView max height so an
    /// XLarge user gets a proportionally larger reading area, not the
    /// same little box with bigger text.
    let textScale: CGFloat
    let onHoverChange: (Bool) -> Void

    /// Base font size at `medium`. The preview is for *reading
    /// content* (long text, code, OCR'd screenshot text) so it uses
    /// the same 13pt baseline the row title uses — not 11pt caption
    /// size.
    static let baseFont: CGFloat = 13
    /// Base cap on the rendered preview height at `medium`. Beyond
    /// this the inner ScrollView handles overflow.
    static let baseMaxHeight: CGFloat = 160

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: Self.baseFont * textScale, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: Self.baseMaxHeight * textScale)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.97))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
        .onHover { onHoverChange($0) }
    }
}
