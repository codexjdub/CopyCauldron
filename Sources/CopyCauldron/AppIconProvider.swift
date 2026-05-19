import AppKit

enum AppIconProvider {
    static func icon(bundleIdentifier: String?, size: NSSize) -> NSImage? {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ) else {
            return nil
        }
        return icon(fileURL: url, size: size)
    }

    static func icon(fileURL: URL, size: NSSize) -> NSImage {
        icon(filePath: fileURL.path, size: size)
    }

    static func icon(filePath: String, size: NSSize) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: filePath)
        image.size = size
        return image
    }
}
