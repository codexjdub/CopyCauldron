import Foundation
import AppKit

// Not `Codable`: persistence is GRDB-only (the `Record` type maps content
// to separate `content_kind` / `text_content` / … columns via a manual
// switch, never through this enum). The custom coders here were dead after
// `ClipboardItem` dropped its own `Codable`.
enum ClipboardContent: Equatable {
    case text(String)
    case image(filename: String)
    case fileURLs([String])
}

struct SourceAppInfo: Equatable {
    let bundleIdentifier: String?
    let name: String

    var displayName: String {
        if !name.isEmpty { return name }
        return bundleIdentifier ?? "Unknown App"
    }
}

struct ClipboardItem: Identifiable, Equatable {
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
    /// Best-effort source app metadata captured from the frontmost app when
    /// the pasteboard change is observed. Browser extensions appear as their
    /// host browser because macOS only exposes the owning app process.
    let sourceApp: SourceAppInfo?
    /// Bookmark data per file URL (one entry per path in `.fileURLs(_)`).
    /// Persisted via SQLite (not JSON) so we can survive renames and moves
    /// — `URL.bookmarkData()` tracks files by inode, not path. `nil` for
    /// non-fileURL items and for legacy rows captured before this field
    /// existed. Resolution is best-effort: callers fall back to the raw
    /// path when the bookmark fails (file deleted, volume unmounted, etc.).
    let fileURLBookmarks: [Data]?
    /// Vision-recognized text for image rows, populated asynchronously
    /// after capture by `OCREngine`. `nil` until recognition completes
    /// (or always nil for pre-OCR rows). Folded into
    /// `lowercasedSearchableText` so the regular search filter finds
    /// screenshots by their on-screen text.
    let ocrText: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: ClipboardContent,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        sourceApp: SourceAppInfo? = nil,
        fileURLBookmarks: [Data]? = nil,
        ocrText: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.sourceApp = sourceApp
        self.fileURLBookmarks = fileURLBookmarks
        self.ocrText = ocrText
        self.textKind = Self.computeKind(from: content)
        self.lowercasedSearchableText = Self.computeSearchableText(
            from: content,
            sourceApp: sourceApp,
            ocrText: ocrText
        )
        self.displayTitle = Self.computeDisplayTitle(from: content)
    }

    private static func computeKind(from content: ClipboardContent) -> TextKind {
        if case .text(let s) = content { return TextKind.detect(in: s) }
        return .plain
    }

    private static func computeSearchableText(
        from content: ClipboardContent,
        sourceApp: SourceAppInfo?,
        ocrText: String?
    ) -> String {
        var parts: [String]
        switch content {
        case .text(let s):
            parts = [s]
        case .image:
            parts = ["image"]
        case .fileURLs(let ps):
            parts = [ps.joined(separator: " ")]
        }
        if let sourceApp {
            parts.append(sourceApp.displayName)
            if let bundleIdentifier = sourceApp.bundleIdentifier {
                parts.append(bundleIdentifier)
            }
        }
        if let ocrText, !ocrText.isEmpty {
            parts.append(ocrText)
        }
        return parts.joined(separator: " ").lowercased()
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

    // No `Codable` conformance: persistence goes through GRDB's separate
    // `Record` type in `HistoryDatabase` (`toRecord` / `fromRecord`), not
    // JSON. The old JSON-backed store was removed in v0.3.0; the custom
    // `Codable` coders that survived it were dead code.

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
