import AppKit
import SwiftUI

enum RowDragPayload {
    case text(TextPastePayload)
    case image(URL)
    case fileURLs([URL])
}

struct RowDragSourceView: NSViewRepresentable {
    /// Called at drag-start to materialize the payload set for this drag.
    /// Returning multiple payloads (multi-select drag) produces one
    /// `NSDraggingSession` carrying all of them; macOS handles mixed
    /// pasteboard types natively.
    let payloads: () -> [RowDragPayload]
    let onClick: (_ shiftHeld: Bool) -> Void
    /// Fires when the user Cmd-clicks the row (mutually exclusive with
    /// `onClick`). The view doesn't paste in this case — the panel uses
    /// the callback to toggle the row in/out of the multi-select set.
    let onCmdClick: () -> Void
    /// Fires when an in-flight drag ends (drop succeeded or cancelled).
    /// The panel uses this to clear its multi-select set after the drag
    /// completes.
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> RowDragSourceNSView {
        let view = RowDragSourceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: RowDragSourceNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: RowDragSourceNSView) {
        view.payloadsProvider = payloads
        view.onClick = onClick
        view.onCmdClick = onCmdClick
        view.onDragEnded = onDragEnded
    }
}

final class RowDragSourceNSView: NSView, NSDraggingSource {
    var payloadsProvider: () -> [RowDragPayload] = { [] }
    var onClick: ((Bool) -> Void)?
    var onCmdClick: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch window?.currentEvent?.type ?? NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return self
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted,
              let mouseDownEvent,
              dragDistance(from: mouseDownEvent, to: event) >= dragThreshold else { return }

        let payloads = payloadsProvider()
        let items = draggingItems(for: payloads)
        guard !items.isEmpty else { return }

        dragStarted = true
        beginDraggingSession(with: items, event: mouseDownEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            dragStarted = false
        }
        guard !dragStarted else { return }
        // Cmd takes precedence over Shift: cmd-click is "modify selection"
        // and never pastes, even when shift is also held.
        if event.modifierFlags.contains(.command) {
            onCmdClick?()
        } else {
            onClick?(event.modifierFlags.contains(.shift))
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func dragDistance(from startEvent: NSEvent, to currentEvent: NSEvent) -> CGFloat {
        let start = convert(startEvent.locationInWindow, from: nil)
        let current = convert(currentEvent.locationInWindow, from: nil)
        let dx = current.x - start.x
        let dy = current.y - start.y
        return hypot(dx, dy)
    }

    /// Flattens N payloads into a single `[NSDraggingItem]` for one
    /// dragging session. Drag-preview stacking uses the running index
    /// across all items so a mixed multi-drag (text + image + files)
    /// still produces a tidy stacked preview.
    private func draggingItems(for payloads: [RowDragPayload]) -> [NSDraggingItem] {
        var nested: [[(NSPasteboardWriting, NSImage)]] = []
        for payload in payloads {
            nested.append(writerImagePairs(for: payload))
        }
        let total = nested.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var out: [NSDraggingItem] = []
        var index = 0
        for group in nested {
            for (writer, image) in group {
                out.append(draggingItem(writer: writer, image: image,
                                        index: index, count: total))
                index += 1
            }
        }
        return out
    }

    /// Returns the `(NSPasteboardWriting, drag-preview NSImage)` pairs
    /// for one payload. File-URL payloads expand to one pair per file
    /// (so Finder sees a real multi-file drop); other payloads produce a
    /// single pair.
    private func writerImagePairs(for payload: RowDragPayload)
        -> [(NSPasteboardWriting, NSImage)] {
        switch payload {
        case .text(let payload):
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(payload.string, forType: .string)
            if let rtfData = payload.rtfData {
                pasteboardItem.setData(rtfData, forType: .rtf)
            }
            if let htmlData = payload.htmlData {
                pasteboardItem.setData(htmlData, forType: .html)
            }
            return [(pasteboardItem, dragImage(systemSymbol: "text.alignleft"))]

        case .image(let url):
            let pasteboardItem = NSPasteboardItem()
            // Read the file once and reuse the bytes for both the PNG
            // pasteboard payload and the NSImage used as the drag preview.
            let data = try? Data(contentsOf: url)
            var image = data.flatMap { NSImage(data: $0) }
            if let data {
                pasteboardItem.setData(data, forType: .png)
                if let tiff = image?.tiffRepresentation {
                    pasteboardItem.setData(tiff, forType: .tiff)
                }
            }
            pasteboardItem.setString(url.absoluteString, forType: .fileURL)
            return [(pasteboardItem, dragImage(from: &image, fallbackSymbol: "photo"))]

        case .fileURLs(let urls):
            let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existingURLs.isEmpty else {
                // Fallback when none of the files still exist: drop the
                // paths as text so the user at least gets something.
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                return [(pasteboardItem, dragImage(systemSymbol: "doc.on.doc"))]
            }
            return existingURLs.map { url in
                (url as NSURL, dragImage(fileURL: url))
            }
        }
    }

    private func draggingItem(writer: NSPasteboardWriting,
                              image: NSImage,
                              index: Int,
                              count: Int) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(draggingFrame(index: index, count: count), contents: image)
        return item
    }

    private func draggingFrame(index: Int, count: Int) -> NSRect {
        let size = NSSize(width: 32, height: 32)
        let fallbackPoint = NSPoint(x: bounds.midX, y: bounds.midY)
        let location = mouseDownEvent.map { convert($0.locationInWindow, from: nil) } ?? fallbackPoint
        let visibleIndex = min(index, 4)
        let offset = CGFloat(visibleIndex) * 3
        return NSRect(
            x: location.x - size.width / 2 + offset,
            y: location.y - size.height / 2 - offset,
            width: size.width,
            height: size.height
        )
    }

    private func dragImage(fileURL: URL) -> NSImage {
        AppIconProvider.icon(fileURL: fileURL, size: NSSize(width: 32, height: 32))
    }

    private func dragImage(from image: inout NSImage?, fallbackSymbol: String) -> NSImage {
        guard let image else { return dragImage(systemSymbol: fallbackSymbol) }
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    private func dragImage(systemSymbol: String) -> NSImage {
        let image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 32, height: 32))
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}
