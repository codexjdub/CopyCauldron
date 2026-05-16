import AppKit
import ImageIO
import SwiftUI

/// Background-decoded, downsampled thumbnail cache for image rows.
///
/// `NSImage(contentsOf:)` inside SwiftUI's `body` synchronously decodes the
/// full PNG every render — for a panel of 20 image rows scrolling past, that's
/// 20 main-thread decodes per scroll tick. This cache decodes once per
/// filename on a userInitiated background queue, downsamples to a small fixed
/// pixel size via `CGImageSourceCreateThumbnailAtIndex`, and serves
/// subsequent reads from memory.
///
/// `NSCache` automatically evicts under memory pressure, so we don't need to
/// manage size limits manually.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(
        label: "CopyCauldron.thumbnail",
        qos: .userInitiated
    )

    private init() {}

    /// Returns the cached thumbnail synchronously if present, or `nil` and
    /// triggers an async decode that will call `completion` on the main queue.
    @discardableResult
    func thumbnail(
        for url: URL,
        maxPixelSize: Int = 64,
        completion: @escaping (NSImage?) -> Void
    ) -> NSImage? {
        let key = "\(url.path)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return cached
        }
        queue.async { [weak self] in
            let image = Self.makeThumbnail(url: url, maxPixelSize: maxPixelSize)
            if let image {
                self?.cache.setObject(image, forKey: key)
            }
            DispatchQueue.main.async { completion(image) }
        }
        return nil
    }

    private static func makeThumbnail(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: maxPixelSize, height: maxPixelSize)
        )
    }

    /// File extensions we'll attempt to decode as image thumbnails. Anything
    /// else falls back to `NSWorkspace.shared.icon(forFile:)` (cheap, no
    /// caching needed).
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif",
        "tiff", "tif", "bmp", "webp"
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}

/// SwiftUI wrapper that shows a placeholder until the thumbnail arrives.
/// Pulls from `ThumbnailCache.shared`; subsequent appearances of the same URL
/// are served from cache instantly.
struct CachedThumbnail<Placeholder: View>: View {
    let url: URL
    let maxPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _ in
            image = nil
            load()
        }
    }

    private func load() {
        // Synchronous cache hit short-circuits the closure; otherwise the
        // async decode calls back on main and updates `image`.
        if let cached = ThumbnailCache.shared.thumbnail(
            for: url, maxPixelSize: maxPixelSize, completion: { fetched in
                self.image = fetched
            }
        ) {
            self.image = cached
        }
    }
}
