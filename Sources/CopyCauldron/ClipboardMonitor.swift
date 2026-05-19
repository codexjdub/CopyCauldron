import Foundation
import AppKit

@MainActor
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let preferences: Preferences
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    /// Exact pasteboard change count from our own most recent write. We only
    /// skip that specific change; if the user copies something else before
    /// the next poll, it has a different change count and gets captured.
    private var suppressedChangeCount: Int?

    /// Pasteboard poll cadence. macOS has no clipboard-change notification, so
    /// we poll `changeCount`. 1.0s matches Maccy/Pastebot and halves the
    /// timer rate vs the previous 500ms; worst-case latency between a copy
    /// and the item appearing in the panel is ~1s, which is below the time
    /// it takes a user to actually open the panel.
    private static let pollInterval: TimeInterval = 1.0

    init(store: ClipboardStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if suppressedChangeCount == current {
            suppressedChangeCount = nil
            return
        }
        suppressedChangeCount = nil

        guard let item = readCurrent() else { return }
        store.add(item)
    }

    /// Called immediately after CopyCauldron writes an item back to the
    /// pasteboard for paste. The next poll should ignore only this exact
    /// write-back, not the user's next real copy.
    func suppressCurrentChangeCount() {
        suppressedChangeCount = pasteboard.changeCount
    }

    private func readCurrent() -> ClipboardItem? {
        let sourceApp = currentSourceApp()
        if preferences.isExcluded(bundleIdentifier: sourceApp?.bundleIdentifier) {
            return nil
        }

        // File URLs first — many apps put both file URLs and a text fallback on
        // the pasteboard; we want to treat it as files.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }
            // Create per-file bookmarks alongside the paths so the menu
            // actions can survive renames/moves. No `.minimalBookmark` —
            // we're not sandboxed, so no security-scope dance is needed.
            // A failed bookmark is represented as empty `Data`; if every
            // entry fails (likely the source pasteboard had transient
            // URLs), drop the whole array so resolvers fall through to
            // the raw-path branch unambiguously.
            let bookmarks: [Data] = urls.map { url in
                (try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )) ?? Data()
            }
            let resolvedBookmarks: [Data]? = bookmarks.allSatisfy(\.isEmpty) ? nil : bookmarks
            return ClipboardItem(
                content: .fileURLs(paths),
                sourceApp: sourceApp,
                fileURLBookmarks: resolvedBookmarks
            )
        }

        // Image
        if let types = pasteboard.types,
            types.contains(.tiff) || types.contains(.png) {
            if let data = pasteboard.data(forType: .png) {
                let filename = store.saveImage(data, ext: "png")
                return ClipboardItem(
                    content: .image(filename: filename),
                    sourceApp: sourceApp
                )
            }
            if let tiff = pasteboard.data(forType: .tiff),
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let filename = store.saveImage(png, ext: "png")
                return ClipboardItem(
                    content: .image(filename: filename),
                    sourceApp: sourceApp
                )
            }
        }

        // Text — capture RTF/HTML too when present so we can offer rich-text paste.
        if let s = pasteboard.string(forType: .string), !s.isEmpty {
            let rtf  = pasteboard.data(forType: .rtf)
            let html = pasteboard.data(forType: .html)
            return ClipboardItem(
                content: .text(s),
                rtfData: rtf,
                htmlData: html,
                sourceApp: sourceApp
            )
        }

        return nil
    }

    private func currentSourceApp() -> SourceAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        guard app.bundleIdentifier != nil || app.localizedName != nil else { return nil }
        return SourceAppInfo(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown App"
        )
    }

}
