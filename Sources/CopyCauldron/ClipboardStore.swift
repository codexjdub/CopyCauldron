import Foundation
import AppKit
import Combine
import GRDB

/// SwiftUI-facing wrapper around the SQLite-backed `HistoryDatabase`.
///
/// `items` is a derived view: the database is the source of truth, and we
/// subscribe to its change-observation. Every mutation writes to the DB and
/// the observation fires, updating `items` on the main queue.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    /// Cap on total items kept in history. Settable from Preferences.
    var maxHistoryItems: Int = Preferences.defaultMaxHistoryItems {
        didSet {
            guard maxHistoryItems != oldValue else { return }
            evictIfNeeded()
        }
    }
    /// Cap on how many items the user can pin. Settable from Preferences.
    var maxPinnedItems: Int = Preferences.defaultMaxPinnedItems

    /// TTL window for the periodic sweep. `.off` disables expiry. Settable
    /// from Preferences; assigning a new value triggers an immediate sweep
    /// so shortening the window evicts now-stale items right away.
    var retentionPeriod: RetentionPeriod = .off {
        didSet {
            guard retentionPeriod != oldValue else { return }
            sweepExpiredItems()
        }
    }

    private let supportDir: URL
    private let imagesDir: URL
    private let database: HistoryDatabase
    private var observationCancellable: AnyDatabaseCancellable?
    private var ttlSweepTimer: Timer?

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.supportDir = base.appendingPathComponent("CopyCauldron", isDirectory: true)
        self.imagesDir = supportDir.appendingPathComponent("images", isDirectory: true)

        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        // v0.3.0 dropped the JSON-backed store. Remove the legacy file so it
        // doesn't sit around taking space. Pre-existing history is *not*
        // migrated — see the v0.3.0 release notes / TODO.md decision.
        let legacyJSON = supportDir.appendingPathComponent("history.json")
        try? fm.removeItem(at: legacyJSON)

        let dbURL = supportDir.appendingPathComponent("history.db")
        do {
            self.database = try HistoryDatabase(url: dbURL)
        } catch {
            // The app is useless without persistence — fail loudly so the
            // user sees the system crash report rather than a silently broken
            // clipboard manager.
            fatalError("CopyCauldron: failed to open history database at \(dbURL.path): \(error)")
        }

        // ValueObservation delivers the initial snapshot asynchronously. The
        // panel isn't shown until the user clicks, by which time `items` has
        // populated, so the brief empty window is invisible in practice.
        observationCancellable = database.observeItems(
            onError: { error in
                NSLog("CopyCauldron: history observation error: \(error)")
            },
            onChange: { [weak self] items in
                Task { @MainActor in
                    self?.items = items
                }
            }
        )

        cleanOrphanImages()
        startTTLSweepTimer()
    }

    // MARK: – Orphan-image cleanup

    /// Deletes `.png` files in `imagesDir` that aren't referenced by any
    /// item in the database. Covers two rare cases:
    /// 1. The app crashed between `saveImage` writing the file and the DB
    ///    INSERT in `add()`.
    /// 2. `cleanup(_:)` silently failed to delete a file on item removal
    ///    (we use `try?` there to avoid disrupting the user-visible flow).
    private func cleanOrphanImages() {
        do {
            let referenced = Set(try database.allImageFilenames())
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(
                at: imagesDir,
                includingPropertiesForKeys: nil
            )
            for file in files {
                guard !referenced.contains(file.lastPathComponent) else { continue }
                try? fm.removeItem(at: file)
            }
        } catch {
            NSLog("CopyCauldron: orphan image cleanup failed: \(error)")
        }
    }

    // MARK: – TTL sweep

    /// Evicts unpinned items older than the current retention window.
    /// No-op when `retentionPeriod == .off`. Pinned items are never expired.
    private func sweepExpiredItems() {
        guard let retentionSeconds = retentionPeriod.seconds else { return }
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        do {
            let evicted = try database.evictExpired(olderThan: cutoff)
            for item in evicted { cleanup(item) }
        } catch {
            NSLog("CopyCauldron: TTL sweep failed: \(error)")
        }
    }

    /// Fires the sweep every 60 minutes. The timer is always-on (cheap to
    /// fire and no-op when `retentionPeriod == .off`); we don't bother
    /// starting/stopping it as the setting toggles.
    private func startTTLSweepTimer() {
        ttlSweepTimer?.invalidate()
        ttlSweepTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepExpiredItems() }
        }
    }

    // MARK: – Mutations

    func add(_ item: ClipboardItem) {
        do {
            // Dedupe against the most recent unpinned item with the same
            // content (most apps re-fire the same string into the pasteboard
            // when you click-then-click; we don't want dupes piling up).
            if try database.mostRecentUnpinnedMatches(item) {
                return
            }
            try database.add(item)
            let evicted = try database.evictUnpinnedIfNeeded(
                maxHistoryItems: maxHistoryItems
            )
            for item in evicted { cleanup(item) }
        } catch {
            NSLog("CopyCauldron: failed to add item: \(error)")
        }
    }

    func remove(_ item: ClipboardItem) {
        do {
            try database.remove(id: item.id)
            cleanup(item)
        } catch {
            NSLog("CopyCauldron: failed to remove item: \(error)")
        }
    }

    func clear() {
        do {
            let removed = try database.clearUnpinned()
            for item in removed { cleanup(item) }
        } catch {
            NSLog("CopyCauldron: failed to clear items: \(error)")
        }
    }

    /// Toggles pin state. Returns `false` if pinning was rejected because the
    /// max-pinned limit was reached.
    @discardableResult
    func togglePin(_ item: ClipboardItem) -> Bool {
        do {
            let result = try database.togglePin(
                id: item.id,
                maxPinned: maxPinnedItems
            )
            return result == .ok
        } catch {
            NSLog("CopyCauldron: failed to toggle pin: \(error)")
            return false
        }
    }

    private func evictIfNeeded() {
        do {
            let evicted = try database.evictUnpinnedIfNeeded(
                maxHistoryItems: maxHistoryItems
            )
            for item in evicted { cleanup(item) }
        } catch {
            NSLog("CopyCauldron: failed to evict items: \(error)")
        }
    }

    // MARK: – Image side files

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
            let url = imageURL(for: filename)
            try? FileManager.default.removeItem(at: url)
            // Drop the in-memory thumbnail too — otherwise NSCache would
            // keep holding a stale `NSImage` until memory pressure kicked
            // in, even though the underlying file is gone.
            ThumbnailCache.shared.evict(url: url)
        }
    }

    // MARK: – Pasteboard write-back

    /// Writes the item back to the system pasteboard so the user can ⌘V.
    /// When `plainTextOnly` is true, attached RTF/HTML is skipped and excessive
    /// blank lines are compacted for pasting into plain-text editors.
    func copyToPasteboard(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.content {
        case .text(let s):
            let pasteString = plainTextOnly
                ? TextPasteTransform.compactPlainText(s)
                : s
            // Declare all the types we'll write up front so the target app
            // sees the full set.
            var types: [NSPasteboard.PasteboardType] = [.string]
            if !plainTextOnly {
                if item.rtfData  != nil { types.append(.rtf) }
                if item.htmlData != nil { types.append(.html) }
            }
            pb.declareTypes(types, owner: nil)
            pb.setString(pasteString, forType: .string)
            if !plainTextOnly {
                if let rtf  = item.rtfData  { pb.setData(rtf,  forType: .rtf)  }
                if let html = item.htmlData { pb.setData(html, forType: .html) }
            }
        case .image(let filename):
            if let data = try? Data(contentsOf: imageURL(for: filename)),
               let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        case .fileURLs:
            let urls = item
                .resolveAllFileURLs()
                .filter(\.exists)
                .map { $0.url as NSURL }
            pb.writeObjects(urls)
        }
    }
}
