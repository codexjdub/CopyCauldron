import Foundation
import AppKit
import Combine

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    /// Cap on total items kept in history. Settable from Preferences.
    var maxHistoryItems: Int = Preferences.defaultMaxHistoryItems {
        didSet {
            guard maxHistoryItems != oldValue else { return }
            evictIfNeeded()
            save()
        }
    }
    /// Cap on how many items the user can pin. Settable from Preferences.
    var maxPinnedItems: Int = Preferences.defaultMaxPinnedItems
    private let supportDir: URL
    private let imagesDir: URL
    private let historyFile: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.supportDir = base.appendingPathComponent("CopyCauldron", isDirectory: true)
        self.imagesDir = supportDir.appendingPathComponent("images", isDirectory: true)
        self.historyFile = supportDir.appendingPathComponent("history.json")

        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    func add(_ item: ClipboardItem) {
        // Dedupe against the most recent unpinned item with the same content.
        if let recent = items.first(where: { !$0.isPinned }),
           recent.content == item.content {
            return
        }
        // Insert after pinned block but before any other unpinned items.
        let insertIndex = items.firstIndex(where: { !$0.isPinned }) ?? items.count
        items.insert(item, at: insertIndex)
        evictIfNeeded()
        save()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        cleanup(item)
        save()
    }

    func clear() {
        // Keep pinned items; only clear unpinned history.
        let toRemove = items.filter { !$0.isPinned }
        for item in toRemove { cleanup(item) }
        items = items.filter { $0.isPinned }
        save()
    }

    /// Toggles pin state. Returns `false` if pinning was rejected because the
    /// max-pinned limit was reached.
    @discardableResult
    func togglePin(_ item: ClipboardItem) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return false }
        if !items[idx].isPinned {
            // About to pin — enforce the cap.
            let pinnedCount = items.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
            if pinnedCount >= maxPinnedItems { return false }
            items[idx].isPinned = true
            items[idx].pinnedAt = Date()
        } else {
            items[idx].isPinned = false
            items[idx].pinnedAt = nil
        }
        // Sort: pinned first (oldest pin → newest pin), then unpinned by recency.
        items.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.isPinned {
                return (lhs.pinnedAt ?? lhs.timestamp) < (rhs.pinnedAt ?? rhs.timestamp)
            }
            return lhs.timestamp > rhs.timestamp
        }
        save()
        return true
    }

    /// Evict only unpinned items past the limit. Pinned items always stay.
    private func evictIfNeeded() {
        guard items.count > maxHistoryItems else { return }
        var unpinnedCount = items.reduce(0) { $0 + ($1.isPinned ? 0 : 1) }
        let pinnedCount = items.count - unpinnedCount
        let unpinnedAllowed = max(0, maxHistoryItems - pinnedCount)
        guard unpinnedCount > unpinnedAllowed else { return }
        // Walk from the tail removing unpinned items until we're within budget.
        var i = items.count - 1
        while i >= 0 && unpinnedCount > unpinnedAllowed {
            if !items[i].isPinned {
                cleanup(items[i])
                items.remove(at: i)
                unpinnedCount -= 1
            }
            i -= 1
        }
    }

    func imageURL(for filename: String) -> URL {
        imagesDir.appendingPathComponent(filename)
    }

    func saveImage(_ data: Data, ext: String = "png") -> String {
        let filename = "\(UUID().uuidString).\(ext)"
        let url = imageURL(for: filename)
        try? data.write(to: url)
        return filename
    }

    private func cleanup(_ item: ClipboardItem) {
        if case .image(let filename) = item.content {
            try? FileManager.default.removeItem(at: imageURL(for: filename))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClipboardItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: historyFile, options: .atomic)
        }
    }

    /// Writes the item back to the system pasteboard so the user can ⌘V.
    /// When `plainTextOnly` is true, attached RTF is skipped — useful for
    /// pasting into editors that misinterpret rich formatting.
    func copyToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.content {
        case .text(let s):
            // Declare all the types we'll write up front so the target app
            // sees the full set.
            var types: [NSPasteboard.PasteboardType] = [.string]
            if !plainTextOnly {
                if item.rtfData  != nil { types.append(.rtf) }
                if item.htmlData != nil { types.append(.html) }
            }
            pb.declareTypes(types, owner: nil)
            pb.setString(s, forType: .string)
            if !plainTextOnly {
                if let rtf  = item.rtfData  { pb.setData(rtf,  forType: .rtf)  }
                if let html = item.htmlData { pb.setData(html, forType: .html) }
            }
        case .image(let filename):
            if let data = try? Data(contentsOf: imageURL(for: filename)),
               let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        case .fileURLs(let paths):
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
    }
}
