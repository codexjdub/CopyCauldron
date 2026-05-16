import Foundation
import AppKit

enum ClipboardContent: Codable, Equatable {
    case text(String)
    case image(filename: String)
    case fileURLs([String])

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case text, image, fileURLs }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .value)
        case .image(let filename):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(filename, forKey: .value)
        case .fileURLs(let paths):
            try c.encode(Kind.fileURLs, forKey: .kind)
            try c.encode(paths, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:     self = .text(try c.decode(String.self, forKey: .value))
        case .image:    self = .image(filename: try c.decode(String.self, forKey: .value))
        case .fileURLs: self = .fileURLs(try c.decode([String].self, forKey: .value))
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let content: ClipboardContent
    var isPinned: Bool
    /// When the user pinned the item (nil if not pinned). Newer pinnedAt sorts
    /// later in the pinned section.
    var pinnedAt: Date?
    /// Rich-text payload (RTF data) captured alongside the plain string, when
    /// the source app put one on the pasteboard. Only meaningful for `.text`
    /// content. nil for plain-only items.
    var rtfData: Data?
    /// HTML payload — many apps (browsers, Notes) put HTML on the pasteboard
    /// instead of RTF.
    var htmlData: Data?
    /// Detected text classification (URL / email / JSON / color / etc.) used
    /// by `ItemRow` to pick a row icon. Computed once at construction time so
    /// SwiftUI rows don't re-run `TextKind.detect` on every body re-render
    /// (the detector is expensive: it instantiates `NSDataDetector` and runs
    /// several regexes). Not persisted — recomputed on every load.
    let textKind: TextKind
    /// Pre-lowercased searchable form used by `PanelView`'s filter. Computed
    /// once at construction time so each keystroke in the search field
    /// doesn't allocate a fresh lowercased copy of every item's content.
    /// Not persisted — recomputed on every load.
    let lowercasedSearchableText: String
    /// Pre-computed display title for the row (≤80 chars, single-line).
    /// Computed once at construction so huge text items don't re-trim and
    /// re-replace-occurrences inside the SwiftUI body on every render.
    /// Not persisted — recomputed on every load.
    let displayTitle: String
    /// Bookmark data per file URL (one entry per path in `.fileURLs(_)`).
    /// Persisted via SQLite (not JSON) so we can survive renames and moves
    /// — `URL.bookmarkData()` tracks files by inode, not path. `nil` for
    /// non-fileURL items and for legacy rows captured before this field
    /// existed. Resolution is best-effort: callers fall back to the raw
    /// path when the bookmark fails (file deleted, volume unmounted, etc.).
    let fileURLBookmarks: [Data]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: ClipboardContent,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        fileURLBookmarks: [Data]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.fileURLBookmarks = fileURLBookmarks
        self.textKind = Self.computeKind(from: content)
        self.lowercasedSearchableText = Self.computeSearchableText(from: content)
        self.displayTitle = Self.computeDisplayTitle(from: content)
    }

    private static func computeKind(from content: ClipboardContent) -> TextKind {
        if case .text(let s) = content { return TextKind.detect(in: s) }
        return .plain
    }

    private static func computeSearchableText(from content: ClipboardContent) -> String {
        switch content {
        case .text(let s):       return s.lowercased()
        case .image:             return "image"
        case .fileURLs(let ps):  return ps.joined(separator: " ").lowercased()
        }
    }

    private static func computeDisplayTitle(from content: ClipboardContent) -> String {
        switch content {
        case .text(let s):
            // Bound the work up front so huge text items don't pay
            // 30MB×2 of trim/replace allocation just to produce 80 chars.
            // 500-char prefix is plenty of headroom after whitespace trim.
            let bounded = String(s.prefix(500))
            let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
            let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
            return oneLine.isEmpty ? "(empty)" : String(oneLine.prefix(80))
        case .image:
            return "Image"
        case .fileURLs(let paths):
            if paths.count == 1 {
                return (paths[0] as NSString).lastPathComponent
            }
            return "\(paths.count) files"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, content, isPinned, pinnedAt, rtfData, htmlData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.content = try c.decode(ClipboardContent.self, forKey: .content)
        self.isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
        let storedPinnedAt = try? c.decode(Date.self, forKey: .pinnedAt)
        // Backfill: pre-existing pinned items use their own timestamp as the
        // pin time so their order is stable across the upgrade.
        if self.isPinned {
            self.pinnedAt = storedPinnedAt ?? self.timestamp
        } else {
            self.pinnedAt = nil
        }
        self.rtfData = try? c.decode(Data.self, forKey: .rtfData)
        self.htmlData = try? c.decode(Data.self, forKey: .htmlData)
        // `fileURLBookmarks` is intentionally not in CodingKeys — bookmarks
        // are persisted via SQLite, not the (now-dead) JSON path. Older
        // decoded items just get nil here.
        self.fileURLBookmarks = nil
        self.textKind = Self.computeKind(from: self.content)
        self.lowercasedSearchableText = Self.computeSearchableText(from: self.content)
        self.displayTitle = Self.computeDisplayTitle(from: self.content)
    }

    // Explicit encode: `textKind` is derived from `content`, so we don't write
    // it (and the Codable synthesizer can't auto-generate this anyway with the
    // extra non-Codable property in the mix).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(content, forKey: .content)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encodeIfPresent(rtfData, forKey: .rtfData)
        try c.encodeIfPresent(htmlData, forKey: .htmlData)
    }

    var iconSystemName: String {
        switch content {
        case .text:     return "text.alignleft"
        case .image:    return "photo"
        case .fileURLs: return "doc.on.doc"
        }
    }
}

/// Result of resolving a `.fileURLs` entry via its bookmark (with raw-path
/// fallback). Callers should consult `exists` before performing
/// filesystem-touching actions (`open`, `reveal in Finder`).
struct ResolvedFileURL {
    let url: URL
    /// `true` when the bookmark resolved but the file has moved/renamed
    /// since capture. The `url` is still valid; refresh callers can replace
    /// the stored bookmark if they care.
    let isStale: Bool
    /// `false` when the file no longer exists at the resolved location.
    let exists: Bool
}

extension ClipboardItem {
    /// Resolves a single file URL for a `.fileURLs` item. Prefers the stored
    /// bookmark (follows renames/moves); falls back to the raw stored path.
    /// Returns nil for non-fileURL items or out-of-range indices.
    func resolveFileURL(at index: Int) -> ResolvedFileURL? {
        guard case .fileURLs(let paths) = content, index < paths.count else { return nil }
        let path = paths[index]
        if let bookmarks = fileURLBookmarks, index < bookmarks.count {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarks[index],
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return ResolvedFileURL(
                    url: url,
                    isStale: isStale,
                    exists: FileManager.default.fileExists(atPath: url.path)
                )
            }
        }
        let url = URL(fileURLWithPath: path)
        return ResolvedFileURL(
            url: url,
            isStale: false,
            exists: FileManager.default.fileExists(atPath: path)
        )
    }

    /// Resolves every path in a `.fileURLs` item. Empty for other content
    /// kinds. Order matches the stored paths array.
    func resolveAllFileURLs() -> [ResolvedFileURL] {
        guard case .fileURLs(let paths) = content else { return [] }
        return (0..<paths.count).compactMap { resolveFileURL(at: $0) }
    }
}
