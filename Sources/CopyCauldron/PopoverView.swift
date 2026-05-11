import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox

struct PopoverView: View {
    @ObservedObject var store: ClipboardStore
    /// Activate an item. `invertPlainText` is true when the user held Shift —
    /// the activator should flip the plain-text-only preference for this paste.
    let onCopy: (ClipboardItem, Bool) -> Void
    let onQuit: () -> Void
    let onPreferences: () -> Void
    let onClose: () -> Void
    let initialSize: CGSize
    let onResize: (CGSize) -> Void
    let onResizeEnd: (CGSize) -> Void
    let popoverOpened: AnyPublisher<Void, Never>

    @State private var query: String = ""
    @State private var size: CGSize
    @State private var dragStartSize: CGSize?
    @State private var selectedID: UUID?
    @State private var keyMonitor: Any?
    @State private var previewItemID: UUID?
    @FocusState private var searchFocused: Bool

    init(
        store: ClipboardStore,
        onCopy: @escaping (ClipboardItem, Bool) -> Void,
        onQuit: @escaping () -> Void,
        onPreferences: @escaping () -> Void,
        onClose: @escaping () -> Void,
        initialSize: CGSize,
        onResize: @escaping (CGSize) -> Void,
        onResizeEnd: @escaping (CGSize) -> Void,
        popoverOpened: AnyPublisher<Void, Never>
    ) {
        self.store = store
        self.onCopy = onCopy
        self.onQuit = onQuit
        self.onPreferences = onPreferences
        self.onClose = onClose
        self.initialSize = initialSize
        self.onResize = onResize
        self.onResizeEnd = onResizeEnd
        self.popoverOpened = popoverOpened
        _size = State(initialValue: initialSize)
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

    /// Keys used as pin shortcuts, in order: 1–9, then a–z. 35 total slots.
    private static let pinShortcutLabels: [String] =
        (1...9).map(String.init) + "abcdefghijklmnopqrstuvwxyz".map(String.init)

    /// Maps a pinned item's id → its shortcut label ("1"…"9", "a"…"z").
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
        .frame(width: size.width, height: size.height)
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
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartSize == nil { dragStartSize = size }
                            let start = dragStartSize ?? size
                            let proposed = CGSize(
                                width: start.width + value.translation.width,
                                height: start.height + value.translation.height
                            )
                            let clamped = clampSize(proposed)
                            size = clamped
                            onResize(clamped)
                        }
                        .onEnded { _ in
                            dragStartSize = nil
                            onResizeEnd(size)
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .onAppear {
            selectedID = store.items.first?.id
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onReceive(popoverOpened) { _ in
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

        // Pin shortcuts — only when the search field isn't focused, so typing
        // those characters into search still works. 1–9 cover the first 9
        // pinned items; a–z cover pins 10–35.
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

    private func clampSize(_ s: CGSize) -> CGSize {
        let minS = Preferences.minPopoverSize
        let maxS = Preferences.maxPopoverSize
        return CGSize(
            width:  min(max(s.width,  minS.width),  maxS.width),
            height: min(max(s.height, minS.height), maxS.height)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard", text: $query)
                .textFieldStyle(.plain)
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
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
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
            Button("Quit") { onQuit() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct HoverPreviewPanel: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
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

private struct ResizeGrip: View {
    var body: some View {
        Canvas { ctx, _ in
            let color = GraphicsContext.Shading.color(.secondary)
            var path = Path()
            // Three diagonal strokes in the bottom-right corner.
            path.move(to: CGPoint(x: 13, y: 4));  path.addLine(to: CGPoint(x: 4, y: 13))
            path.move(to: CGPoint(x: 13, y: 8));  path.addLine(to: CGPoint(x: 8, y: 13))
            path.move(to: CGPoint(x: 13, y: 12)); path.addLine(to: CGPoint(x: 12, y: 13))
            ctx.stroke(path, with: color, lineWidth: 1.25)
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
    }
}

private struct ItemRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let shortcutLabel: String?
    let isSelected: Bool
    let onCopy: (ClipboardItem, Bool) -> Void
    /// Called with the item's id when the cursor has lingered on the row long
    /// enough to show a preview, or nil when the cursor leaves.
    let onLingerHover: (UUID?) -> Void

    @State private var hovering = false
    @State private var lingerWorkItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
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
            if hovering || item.isPinned {
                Button {
                    if !store.togglePin(item) {
                        showPinLimitAlert()
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
        .onTapGesture {
            // Detect shift on the click. `NSEvent.modifierFlags` reads the
            // global modifier state directly — more reliable than
            // `NSApp.currentEvent` which can be stale or nil by the time
            // SwiftUI dispatches the tap closure.
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            onCopy(item, shiftHeld)
        }
        .contextMenu { contextMenuItems }
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

    private func showPinLimitAlert() {
        let alert = NSAlert()
        alert.messageText = "Pin limit reached"
        alert.informativeText = "You've hit the maximum number of pinned items (\(store.maxPinnedItems)). Increase the limit in Preferences or unpin an item first."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
