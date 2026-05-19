import AppKit
import SwiftUI

enum RowDragPayload {
    case text(TextPastePayload)
    case image(URL)
    case fileURLs([URL])
}

struct RowDragSourceView: NSViewRepresentable {
    let payload: RowDragPayload
    let onClick: (Bool) -> Void

    func makeNSView(context: Context) -> RowDragSourceNSView {
        let view = RowDragSourceNSView()
        view.payload = payload
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: RowDragSourceNSView, context: Context) {
        nsView.payload = payload
        nsView.onClick = onClick
    }
}

final class RowDragSourceNSView: NSView, NSDraggingSource {
    var payload: RowDragPayload = .text(
        TextPastePayload(string: "", rtfData: nil, htmlData: nil)
    )
    var onClick: ((Bool) -> Void)?

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

        let items = draggingItems(for: payload)
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
        onClick?(event.modifierFlags.contains(.shift))
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
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

    private func draggingItems(for payload: RowDragPayload) -> [NSDraggingItem] {
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
            return [
                draggingItem(
                    writer: pasteboardItem,
                    image: dragImage(systemSymbol: "text.alignleft"),
                    index: 0,
                    count: 1
                )
            ]

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
            return [
                draggingItem(
                    writer: pasteboardItem,
                    image: dragImage(from: &image, fallbackSymbol: "photo"),
                    index: 0,
                    count: 1
                )
            ]

        case .fileURLs(let urls):
            let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existingURLs.isEmpty else {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                return [
                    draggingItem(
                        writer: pasteboardItem,
                        image: dragImage(systemSymbol: "doc.on.doc"),
                        index: 0,
                        count: 1
                    )
                ]
            }
            return existingURLs.enumerated().map { index, url in
                draggingItem(
                    writer: url as NSURL,
                    image: dragImage(fileURL: url),
                    index: index,
                    count: existingURLs.count
                )
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
