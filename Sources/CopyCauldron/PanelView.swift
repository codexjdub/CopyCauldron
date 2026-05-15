import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var preferences: Preferences
    /// Activate an item. `invertPlainText` is true when the user held Shift —
    /// the activator should flip the plain-text-only preference for this paste.
    let onCopy: (ClipboardItem, Bool) -> Void
    let onPreferences: () -> Void
    let onClose: () -> Void
    let initialSize: CGSize
    let panelOpened: AnyPublisher<Void, Never>

    @State private var query: String = ""
    @State private var selectedID: UUID?
    @State private var keyMonitor: Any?
    @State private var previewItemID: UUID?
    @FocusState private var searchFocused: Bool

    init(
        store: ClipboardStore,
        preferences: Preferences,
        onCopy: @escaping (ClipboardItem, Bool) -> Void,
        onPreferences: @escaping () -> Void,
        onClose: @escaping () -> Void,
        initialSize: CGSize,
        panelOpened: AnyPublisher<Void, Never>
    ) {
        self.store = store
        self.preferences = preferences
        self.onCopy = onCopy
        self.onPreferences = onPreferences
        self.onClose = onClose
        self.initialSize = initialSize
        self.panelOpened = panelOpened
    }

    private var filtered: [ClipboardItem] {
        guard !query.isEmpty else { return store.items }
        let q = query.lowercased()
        return store.items.filter { item in
            switch item.content {
            case .text(let s):       return s.lowercased().contains(q)
            case .image:             return "image".contains(q)
            case .fileURLs(let ps):  return ps.contains { $0.lowercased().contains(q) }
            }
        }
    }

    /// Keys used as pinned-item shortcuts. "p" is reserved to toggle the
    /// selected item's pin state.
    private static let pinShortcutLabels: [String] =
        (1...9).map(String.init) + "abcdefghijklmnoqrstuvwxyz".map(String.init)

    /// Maps a pinned item's id to its shortcut label.
    private var pinnedShortcuts: [UUID: String] {
        var map: [UUID: String] = [:]
        var i = 0
        for item in store.items where item.isPinned {
            guard i < Self.pinShortcutLabels.count else { break }
            map[item.id] = Self.pinShortcutLabels[i]
            i += 1
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowChrome(isPinned: $preferences.keepPanelOpen)
                .frame(height: 18)
            header
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { item in
                                ItemRow(
                                    item: item,
                                    store: store,
                                    shortcutLabel: pinnedShortcuts[item.id],
                                    isSelected: item.id == selectedID,
                                    plainTextOnly: preferences.pastePlainTextOnly,
                                    onCopy: onCopy,
                                    onLingerHover: { lingeringID in
                                        previewItemID = lingeringID
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedID) { newID in
                        if let id = newID {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: Preferences.minPanelSize.width,
               idealWidth: initialSize.width,
               maxWidth: .infinity,
               minHeight: Preferences.minPanelSize.height,
               idealHeight: initialSize.height,
               maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let id = previewItemID,
               let item = store.items.first(where: { $0.id == id }),
               let previewText = previewText(for: item) {
                HoverPreviewPanel(text: previewText)
                    .padding(.horizontal, 10)
                    // Sit just above the footer.
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            selectedID = store.items.first?.id
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onReceive(panelOpened) { _ in
            query = ""
            selectedID = store.items.first?.id
            previewItemID = nil
            // Keep search field unfocused so 1–9 paste pinned items directly.
            // Press / to focus the search field.
            searchFocused = false
        }
        .onChange(of: query) { _ in
            // Keep selection valid after filtering.
            if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
                selectedID = filtered.first?.id
            }
        }
        .onChange(of: store.items.map(\.id)) { _ in
            if selectedID == nil || !filtered.contains(where: { $0.id == selectedID }) {
                selectedID = filtered.first?.id
            }
        }
        .environment(\.textScale, preferences.textSize.scaleFactor)
    }

    // MARK: – Keyboard navigation

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Returns true when the event has been consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyShiftOrNone = mods.subtracting(.shift).isEmpty
        let shiftHeld = mods.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            moveSelection(by: -1)
            return true
        case kVK_Return:
            if let id = selectedID, let item = filtered.first(where: { $0.id == id }) {
                onCopy(item, shiftHeld)
            }
            return true
        case kVK_Escape:
            if searchFocused && !query.isEmpty {
                query = ""
            } else if searchFocused {
                searchFocused = false
            } else {
                onClose()
            }
            return true
        default:
            break
        }

        // `/` focuses the search field when it isn't already focused.
        if onlyShiftOrNone, !searchFocused,
           event.charactersIgnoringModifiers == "/" {
            searchFocused = true
            return true
        }

        if onlyShiftOrNone, !searchFocused,
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            toggleSelectedPin()
            return true
        }

        // Pinned-item shortcuts — only when the search field isn't focused, so
        // typing those characters into search still works.
        if onlyShiftOrNone, !searchFocused,
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let idx = Self.pinShortcutLabels.firstIndex(of: chars) {
            let pinned = store.items.filter { $0.isPinned }
            if idx < pinned.count {
                onCopy(pinned[idx], shiftHeld)
                return true
            }
        }

        return false
    }

    private func toggleSelectedPin() {
        guard let id = selectedID,
              let item = filtered.first(where: { $0.id == id }) else { return }
        if !store.togglePin(item) {
            presentPinLimitAlert(maxPinnedItems: store.maxPinnedItems)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let currentIdx = filtered.firstIndex(where: { $0.id == selectedID }) ?? -1
        let newIdx = max(0, min(filtered.count - 1, currentIdx + delta))
        selectedID = filtered[newIdx].id
    }

    /// Returns text to show in the hover preview panel, or nil when the item
    /// isn't interesting enough to preview (short single-line text, single file).
    private func previewText(for item: ClipboardItem) -> String? {
        switch item.content {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.components(separatedBy: .newlines).count
            guard trimmed.count > 80 || lines > 1 else { return nil }
            return String(trimmed.prefix(2000))
        case .fileURLs(let paths):
            guard paths.count > 1 else { return nil }
            return paths.joined(separator: "\n")
        case .image:
            return nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * preferences.textSize.scaleFactor))
                .focused($searchFocused)
            if !searchFocused {
                Text("/")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    )
                    .help("Press / to search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(store.items.isEmpty ? "No clipboard history yet" : "No matches")
                .font(.system(size: 13 * preferences.textSize.scaleFactor))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.system(size: 11 * preferences.textSize.scaleFactor))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                preferences.pastePlainTextOnly.toggle()
            } label: {
                Text("Plain")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(preferences.pastePlainTextOnly
                                  ? Color.accentColor
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                preferences.pastePlainTextOnly
                                    ? Color.clear
                                    : Color.secondary.opacity(0.5),
                                lineWidth: 1
                            )
                    )
                    .foregroundStyle(
                        preferences.pastePlainTextOnly ? Color.white : Color.primary
                    )
            }
            .buttonStyle(.plain)
            .help(preferences.pastePlainTextOnly
                  ? "Plain-text paste is ON — strips rich formatting. Click to allow rich text."
                  : "Plain-text paste is OFF — rich text preserved. Click to strip formatting.")
            Button {
                onPreferences()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Preferences")
            Button("Clear") { store.clear() }
                .buttonStyle(.borderless)
                .disabled(store.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Wraps `NSVisualEffectView` for use as a SwiftUI background. Produces the
/// translucent "frosted glass" look used by Spotlight, Notification Center, etc.
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

private struct HoverPreviewPanel: View {
    let text: String
    @Environment(\.textScale) private var textScale: CGFloat

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11 * textScale, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.97))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleNSView {
        WindowDragHandleNSView()
    }

    func updateNSView(_ nsView: WindowDragHandleNSView, context: Context) {}
}

private struct WindowChrome: View {
    @Binding var isPinned: Bool

    var body: some View {
        ZStack {
            WindowDragHandle()
                .frame(width: 90)

            HStack(spacing: 0) {
                Text("CopyCauldron")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .frame(width: 120, alignment: .leading)

                Spacer()

                Button {
                    isPinned.toggle()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isPinned ? .orange : .secondary)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Panel stays open" : "Keep panel open")
                .padding(.trailing, 8)
            }
        }
    }
}

private final class WindowDragHandleNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let handleSize = NSSize(width: 34, height: 3)
        let handleRect = NSRect(
            x: bounds.midX - handleSize.width / 2,
            y: bounds.midY - handleSize.height / 2,
            width: handleSize.width,
            height: handleSize.height
        )
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private enum RowDragPayload {
    case text(String, rtfData: Data?, htmlData: Data?)
    case image(URL)
    case fileURLs([URL])
}

private struct RowDragSourceView: NSViewRepresentable {
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

private final class RowDragSourceNSView: NSView, NSDraggingSource {
    var payload: RowDragPayload = .text("", rtfData: nil, htmlData: nil)
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
        case .text(let text, let rtfData, let htmlData):
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(text, forType: .string)
            if let rtfData {
                pasteboardItem.setData(rtfData, forType: .rtf)
            }
            if let htmlData {
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
            var image = NSImage(contentsOf: url)
            if let data = try? Data(contentsOf: url) {
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
        let image = NSWorkspace.shared.icon(forFile: fileURL.path)
        image.size = NSSize(width: 32, height: 32)
        return image
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

private func presentPinLimitAlert(maxPinnedItems: Int) {
    let alert = NSAlert()
    alert.messageText = "Pin limit reached"
    alert.informativeText = "You've hit the maximum number of pinned items (\(maxPinnedItems)). Increase the limit in Preferences or unpin an item first."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

private struct ItemRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let shortcutLabel: String?
    let isSelected: Bool
    let plainTextOnly: Bool
    let onCopy: (ClipboardItem, Bool) -> Void
    /// Called with the item's id when the cursor has lingered on the row long
    /// enough to show a preview, or nil when the cursor leaves.
    let onLingerHover: (UUID?) -> Void

    @State private var hovering = false
    @State private var lingerWorkItem: DispatchWorkItem?
    @Environment(\.textScale) private var textScale: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            dragContent
            if hovering || item.isPinned {
                Button {
                    if !store.togglePin(item) {
                        presentPinLimitAlert(maxPinnedItems: store.maxPinnedItems)
                    }
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin" : "Pin")
            }
            if hovering {
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering in
            hovering = isHovering
            // Cancel any pending linger from a previous hover.
            lingerWorkItem?.cancel()
            if isHovering {
                let work = DispatchWorkItem { onLingerHover(item.id) }
                lingerWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            } else {
                onLingerHover(nil)
            }
        }
        .contextMenu { contextMenuItems }
    }

    private var dragContent: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 13 * textScale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.timestamp.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11 * textScale))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let label = shortcutLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                    )
                    .help("Press \(label) to paste")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay {
            RowDragSourceView(payload: dragPayload) { shiftHeld in
                onCopy(item, shiftHeld)
            }
        }
    }

    private var dragPayload: RowDragPayload {
        switch item.content {
        case .text(let s):
            return .text(
                s,
                rtfData: plainTextOnly ? nil : item.rtfData,
                htmlData: plainTextOnly ? nil : item.htmlData
            )
        case .image(let filename):
            return .image(store.imageURL(for: filename))
        case .fileURLs(let paths):
            return .fileURLs(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch item.content {
        case .fileURLs(let paths):
            Button("Reveal in Finder") { revealInFinder(paths) }
            Button("Open") { openFiles(paths) }
            Button("Copy path as text") { copyPathAsText(paths) }
        case .image(let filename):
            Button("Save as…") { saveImageAs(filename) }
            Button("Open in Preview") { openImage(filename) }
        case .text(let s):
            if let url = detectURL(in: s) {
                Button("Open in browser") { NSWorkspace.shared.open(url) }
            }
        }
    }

    // MARK: – File actions

    private func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func openFiles(_ paths: [String]) {
        for p in paths {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    private func copyPathAsText(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: – Image actions

    private func saveImageAs(_ filename: String) {
        let source = store.imageURL(for: filename)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Image.png"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    private func openImage(_ filename: String) {
        NSWorkspace.shared.open(store.imageURL(for: filename))
    }

    // MARK: – URL detection

    private func detectURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    @ViewBuilder
    private func textPreview(for text: String) -> some View {
        switch TextKind.detect(in: text) {
        case .plain:      typeIcon("text.alignleft")
        case .url:        typeIcon("globe")
        case .email:      typeIcon("envelope")
        case .phone:      typeIcon("phone")
        case .ipAddress:  typeIcon("network")
        case .uuid:       typeIcon("barcode")
        case .gitSHA:     typeIcon("arrow.triangle.branch")
        case .timestamp:  typeIcon("clock")
        case .base64:     typeIcon("lock")
        case .currency:   typeIcon("dollarsign.circle")
        case .hashtag:    typeIcon("number")
        case .mention:    typeIcon("at")
        case .json:
            Text("{ }")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        case .hexColor(let nsColor):
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: nsColor))
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
        }
    }

    private func typeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if hovering   { return Color.secondary.opacity(0.15) }
        return .clear
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let s):
            textPreview(for: s)
        case .image(let filename):
            if let nsimg = NSImage(contentsOf: store.imageURL(for: filename)) {
                Image(nsImage: nsimg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        case .fileURLs(let paths):
            if let first = paths.first {
                if let thumb = Self.imageThumbnail(forPath: first) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    let icon = NSWorkspace.shared.icon(forFile: first)
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                }
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif",
        "tiff", "tif", "bmp", "webp"
    ]

    /// Returns an `NSImage` for image files; nil for other file types or when
    /// the file isn't readable.
    static func imageThumbnail(forPath path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return NSImage(contentsOf: url)
    }
}
