import Foundation
import GRDB

/// SQLite-backed persistence for clipboard items. Wraps a GRDB `DatabasePool`
/// and exposes a small CRUD surface plus a change observation that the store
/// uses to drive its `@Published` items array.
///
/// The schema lives entirely in `migrator` so future changes follow GRDB's
/// migration pattern (one ordered, named migration per change).
final class HistoryDatabase {
    private let dbPool: DatabasePool

    init(url: URL) throws {
        var config = Configuration()
        config.label = "CopyCauldron.HistoryDatabase"
        // Default pool keeps ~5 reader connections + 1 writer open. We use a
        // single observation reader plus occasional CRUD writes, so two is
        // plenty — saves a handful of file descriptors at no perf cost.
        config.maximumReaderCount = 2
        dbPool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(dbPool)
    }

    /// The current schema. Each migration is registered once with a stable
    /// name; GRDB tracks which have run so future upgrades only apply the new
    /// migrations. Add new migrations to the end — never reorder or rename.
    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial_schema") { db in
            try db.create(table: "items") { t in
                t.column("id", .blob).primaryKey()
                t.column("timestamp", .datetime).notNull()
                t.column("content_kind", .text).notNull()
                    .check { ["text", "image", "fileURLs"].contains($0) }
                t.column("text_content", .text)
                t.column("image_filename", .text)
                t.column("file_urls_json", .text)
                t.column("rtf_data", .blob)
                t.column("html_data", .blob)
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
                t.column("pinned_at", .datetime)
            }
            try db.create(
                index: "idx_items_timestamp",
                on: "items",
                columns: ["timestamp"]
            )
            try db.create(
                index: "idx_items_pinned",
                on: "items",
                columns: ["is_pinned", "pinned_at"]
            )
        }
        m.registerMigration("v2_file_url_bookmarks") { db in
            // JSON array of base64-encoded `URL.bookmarkData()` blobs, one per
            // file in `file_urls_json`. Lets us follow renames/moves and
            // detect when the original file is gone.
            try db.alter(table: "items") { t in
                t.add(column: "file_urls_bookmarks_json", .text)
            }
        }
        m.registerMigration("v3_source_app_capture") { db in
            // Best-effort source app metadata captured when the pasteboard
            // change is observed. Existing rows remain nil.
            try db.alter(table: "items") { t in
                t.add(column: "source_app_bundle_id", .text)
                t.add(column: "source_app_name", .text)
            }
            try db.create(
                index: "idx_items_source_app_bundle_id",
                on: "items",
                columns: ["source_app_bundle_id"]
            )
        }
        return m
    }

    // MARK: – Observation

    /// Subscribes to changes and invokes `onChange` (on the main queue) with
    /// the full, display-ordered items list whenever the table mutates.
    ///
    /// Uses `.immediate` scheduling so the initial fetch runs synchronously
    /// on the caller (which must be the main thread) — otherwise the panel
    /// flashes empty for a few ms after launch if the user opens it before
    /// GRDB delivers the first async value. Subsequent changes still arrive
    /// on the main queue.
    func observeItems(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable ([ClipboardItem]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            try Self.fetchAllOrdered(db: db)
        }
        return observation.start(
            in: dbPool,
            scheduling: .immediate,
            onError: onError,
            onChange: onChange
        )
    }

    // MARK: – CRUD

    func add(_ item: ClipboardItem) throws {
        try dbPool.write { db in
            try Self.toRecord(item).insert(db)
        }
    }

    func remove(id: UUID) throws {
        _ = try dbPool.write { db in
            try Record.deleteOne(db, key: id.dataRepresentation)
        }
    }

    /// Deletes all unpinned items and returns the deleted records so the
    /// caller can clean up any associated image files on disk.
    @discardableResult
    func clearUnpinned() throws -> [ClipboardItem] {
        try dbPool.write { db in
            let toRemove = try Record
                .filter(Column("is_pinned") == false)
                .fetchAll(db)
            try Record.filter(Column("is_pinned") == false).deleteAll(db)
            return toRemove.map(Self.fromRecord)
        }
    }

    enum ToggleResult {
        case ok
        case pinLimitReached
        case notFound
    }

    /// Toggles the pin state of an item, enforcing `maxPinned` when pinning.
    func togglePin(id: UUID, maxPinned: Int) throws -> ToggleResult {
        try dbPool.write { db in
            guard var record = try Record.fetchOne(db, key: id.dataRepresentation) else {
                return .notFound
            }
            if !record.isPinned {
                let pinnedCount = try Record
                    .filter(Column("is_pinned") == true)
                    .fetchCount(db)
                if pinnedCount >= maxPinned {
                    return .pinLimitReached
                }
                record.isPinned = true
                record.pinnedAt = Date()
            } else {
                record.isPinned = false
                record.pinnedAt = nil
            }
            try record.update(db)
            return .ok
        }
    }

    /// Deletes unpinned items older than `cutoff` (TTL sweep). Returns the
    /// evicted items so the caller can clean up image files.
    @discardableResult
    func evictExpired(olderThan cutoff: Date) throws -> [ClipboardItem] {
        try dbPool.write { db in
            let toRemove = try Record
                .filter(Column("is_pinned") == false)
                .filter(Column("timestamp") < cutoff)
                .fetchAll(db)
            for record in toRemove {
                try record.delete(db)
            }
            return toRemove.map(Self.fromRecord)
        }
    }

    /// Drops unpinned items past the configured history cap, oldest first.
    /// Returns the evicted items so the caller can clean up image files.
    @discardableResult
    func evictUnpinnedIfNeeded(maxHistoryItems: Int) throws -> [ClipboardItem] {
        try dbPool.write { db in
            let totalCount = try Record.fetchCount(db)
            guard totalCount > maxHistoryItems else { return [] }
            let pinnedCount = try Record
                .filter(Column("is_pinned") == true)
                .fetchCount(db)
            let unpinnedAllowed = max(0, maxHistoryItems - pinnedCount)
            let unpinnedCount = totalCount - pinnedCount
            let evictionCount = max(0, unpinnedCount - unpinnedAllowed)
            guard evictionCount > 0 else { return [] }
            let toRemove = try Record
                .filter(Column("is_pinned") == false)
                .order(Column("timestamp").asc)
                .limit(evictionCount)
                .fetchAll(db)
            for record in toRemove {
                try record.delete(db)
            }
            return toRemove.map(Self.fromRecord)
        }
    }

    /// Every `image_filename` currently referenced by an item — used by the
    /// startup orphan-image sweep to figure out which `.png` files on disk
    /// no longer have a row pointing at them.
    func allImageFilenames() throws -> [String] {
        try dbPool.read { db in
            let records = try Record
                .filter(Column("content_kind") == "image")
                .fetchAll(db)
            return records.compactMap(\.imageFilename)
        }
    }

    /// True when the most recent unpinned item has the same content — used by
    /// `ClipboardStore.add` to dedupe consecutive identical copies.
    func mostRecentUnpinnedMatches(_ item: ClipboardItem) throws -> Bool {
        try dbPool.read { db in
            guard let recent = try Record
                .filter(Column("is_pinned") == false)
                .order(Column("timestamp").desc)
                .fetchOne(db) else {
                return false
            }
            return Self.fromRecord(recent).content == item.content
        }
    }

    // MARK: – Record type

    /// GRDB-mapped row. Kept fileprivate-ish via the `Record` typealias so the
    /// rest of the file can read more naturally.
    fileprivate struct Record: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "items"

        var id: Data            // UUID's 16 raw bytes
        var timestamp: Date
        var contentKind: String // "text" | "image" | "fileURLs"
        var textContent: String?
        var imageFilename: String?
        var fileUrlsJson: String?
        var fileUrlsBookmarksJson: String?
        var sourceAppBundleID: String?
        var sourceAppName: String?
        var rtfData: Data?
        var htmlData: Data?
        var isPinned: Bool
        var pinnedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case timestamp
            case contentKind            = "content_kind"
            case textContent            = "text_content"
            case imageFilename          = "image_filename"
            case fileUrlsJson           = "file_urls_json"
            case fileUrlsBookmarksJson  = "file_urls_bookmarks_json"
            case sourceAppBundleID      = "source_app_bundle_id"
            case sourceAppName          = "source_app_name"
            case rtfData                = "rtf_data"
            case htmlData               = "html_data"
            case isPinned               = "is_pinned"
            case pinnedAt               = "pinned_at"
        }
    }

    // MARK: – Mapping between ClipboardItem and Record

    private static func toRecord(_ item: ClipboardItem) -> Record {
        let kind: String
        var textContent: String?
        var imageFilename: String?
        var fileUrlsJson: String?
        var fileUrlsBookmarksJson: String?

        switch item.content {
        case .text(let s):
            kind = "text"
            textContent = s
        case .image(let filename):
            kind = "image"
            imageFilename = filename
        case .fileURLs(let paths):
            kind = "fileURLs"
            // Paths are small; JSON-encoding into a TEXT column is fine and
            // sidesteps a paths table for what's effectively a value type.
            if let data = try? JSONEncoder().encode(paths) {
                fileUrlsJson = String(data: data, encoding: .utf8)
            } else {
                fileUrlsJson = "[]"
            }
            // Bookmarks travel alongside the paths so we can resolve moves
            // and renames at click time. Encoded as a JSON array of base64
            // strings to mirror the path-array layout.
            if let bookmarks = item.fileURLBookmarks {
                let encoded = bookmarks.map { $0.base64EncodedString() }
                if let data = try? JSONEncoder().encode(encoded) {
                    fileUrlsBookmarksJson = String(data: data, encoding: .utf8)
                }
            }
        }

        return Record(
            id: item.id.dataRepresentation,
            timestamp: item.timestamp,
            contentKind: kind,
            textContent: textContent,
            imageFilename: imageFilename,
            fileUrlsJson: fileUrlsJson,
            fileUrlsBookmarksJson: fileUrlsBookmarksJson,
            sourceAppBundleID: item.sourceApp?.bundleIdentifier,
            sourceAppName: item.sourceApp?.displayName,
            rtfData: item.rtfData,
            htmlData: item.htmlData,
            isPinned: item.isPinned,
            pinnedAt: item.pinnedAt
        )
    }

    private static func fromRecord(_ record: Record) -> ClipboardItem {
        let content: ClipboardContent
        var bookmarks: [Data]? = nil
        switch record.contentKind {
        case "image":
            content = .image(filename: record.imageFilename ?? "")
        case "fileURLs":
            let paths = record.fileUrlsJson
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                ?? []
            content = .fileURLs(paths)
            if let json = record.fileUrlsBookmarksJson,
               let data = json.data(using: .utf8),
               let strings = try? JSONDecoder().decode([String].self, from: data) {
                bookmarks = strings.compactMap { Data(base64Encoded: $0) }
            }
        default: // "text" (and a safe fallback if something unexpected appears)
            content = .text(record.textContent ?? "")
        }
        return ClipboardItem(
            id: UUID(data: record.id) ?? UUID(),
            timestamp: record.timestamp,
            content: content,
            isPinned: record.isPinned,
            pinnedAt: record.pinnedAt,
            rtfData: record.rtfData,
            htmlData: record.htmlData,
            sourceApp: sourceApp(from: record),
            fileURLBookmarks: bookmarks
        )
    }

    private static func sourceApp(from record: Record) -> SourceAppInfo? {
        guard record.sourceAppBundleID != nil || record.sourceAppName != nil else {
            return nil
        }
        let name = record.sourceAppName ?? record.sourceAppBundleID ?? "Unknown App"
        return SourceAppInfo(
            bundleIdentifier: record.sourceAppBundleID,
            name: name
        )
    }

    /// The canonical display order: pinned items first (oldest pin → newest
    /// pin), then unpinned items by recency (newest first). Matches the
    /// behavior the JSON-backed store had.
    private static func fetchAllOrdered(db: Database) throws -> [ClipboardItem] {
        let pinned = try Record
            .filter(Column("is_pinned") == true)
            .order(Column("pinned_at").asc, Column("timestamp").asc)
            .fetchAll(db)
        let unpinned = try Record
            .filter(Column("is_pinned") == false)
            .order(Column("timestamp").desc)
            .fetchAll(db)
        return (pinned + unpinned).map(fromRecord)
    }
}

// MARK: – UUID <-> Data bridge

private extension UUID {
    /// 16 raw bytes for storing as a SQLite BLOB primary key. More compact
    /// than the 36-char string form and round-trips losslessly.
    var dataRepresentation: Data {
        withUnsafePointer(to: uuid) { ptr in
            Data(bytes: ptr, count: MemoryLayout.size(ofValue: uuid))
        }
    }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let uuidBytes: uuid_t = data.withUnsafeBytes { raw in
            raw.load(as: uuid_t.self)
        }
        self.init(uuid: uuidBytes)
    }
}
