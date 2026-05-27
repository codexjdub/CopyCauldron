import SwiftUI
import AppKit

/// Drop target placed under `PanelView` so the user can drag text /
/// images / files from any other app onto the main panel to add them
/// to history. Internal drags from `RowDragSourceNSView` are rejected
/// — those go *out* of the panel and shouldn't loop back in.
///
/// The view is a transparent `.background()` of the panel content so
/// it covers the whole panel area. SwiftUI's `.onDrop` modifier is
/// limited to a single type at a time and offers no per-type
/// inspection of the incoming pasteboard, so we drop down to AppKit's
/// `NSDraggingDestination` directly for full control.
struct PanelDropZone: NSViewRepresentable {
    /// Fired with `true` when an external drag enters the panel,
    /// `false` when it leaves or completes. Used to draw an accent
    /// border around the panel during the drag for visual feedback.
    let isDragOver: (Bool) -> Void
    /// Called on successful drop with the parsed payload — the panel
    /// translates these into `ClipboardItem` and persists via the
    /// store.
    let onDrop: (DroppedPayload) -> Void

    func makeNSView(context: Context) -> PanelDropZoneNSView {
        let view = PanelDropZoneNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PanelDropZoneNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: PanelDropZoneNSView) {
        view.isDragOver = isDragOver
        view.onDrop = onDrop
    }
}

/// Bundle of recognized drag payloads from a single drop. At most one
/// of the three is populated per drop (Finder file drags, image
/// drags, and text drags don't normally mix in one operation).
struct DroppedPayload {
    var fileURLs: [URL] = []
    var images: [NSImage] = []
    var text: String?

    var isEmpty: Bool {
        fileURLs.isEmpty && images.isEmpty && (text?.isEmpty ?? true)
    }
}

final class PanelDropZoneNSView: NSView {
    var isDragOver: ((Bool) -> Void)?
    var onDrop: ((DroppedPayload) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        register()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        register()
    }

    private func register() {
        // Order matters only for our own preference at parse time; AppKit
        // doesn't prioritize — it offers whatever the source provided.
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    // The drop zone shouldn't block clicks on the rows underneath. It
    // only needs to receive drag events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: – NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternalSource(sender) { return [] }
        isDragOver?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isInternalSource(sender) ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragOver?(false)
        if isInternalSource(sender) { return false }
        let payload = parse(sender.draggingPasteboard)
        guard !payload.isEmpty else { return false }
        onDrop?(payload)
        return true
    }

    // MARK: – Helpers

    /// Rejects drags that originated inside CopyCauldron itself —
    /// otherwise dropping your own row onto the panel would re-add
    /// a duplicate. `RowDragSourceNSView` is the only internal drag
    /// source today.
    private func isInternalSource(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource is RowDragSourceNSView
    }

    /// Parses the dragging pasteboard into a `DroppedPayload`. File
    /// URLs take precedence over images, which take precedence over
    /// text — same hierarchy `ClipboardMonitor` uses when capturing
    /// pasteboard changes, so dropped behaviour matches captured
    /// behaviour for the same content.
    private func parse(_ pasteboard: NSPasteboard) -> DroppedPayload {
        var payload = DroppedPayload()
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            payload.fileURLs = urls
            return payload
        }
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage], !images.isEmpty {
            payload.images = images
            return payload
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            payload.text = text
        }
        return payload
    }
}
