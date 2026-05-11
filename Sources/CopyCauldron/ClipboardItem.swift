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

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        content: ClipboardContent,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        rtfData: Data? = nil,
        htmlData: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.rtfData = rtfData
        self.htmlData = htmlData
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
    }

    var displayTitle: String {
        switch content {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    var iconSystemName: String {
        switch content {
        case .text:     return "text.alignleft"
        case .image:    return "photo"
        case .fileURLs: return "doc.on.doc"
        }
    }
}
