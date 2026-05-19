import AppKit
import UniformTypeIdentifiers

enum AppBundleResolver {
    static func chooseApplicationURLs() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps to Exclude"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    static func excludedAppInfo(at url: URL) -> ExcludedAppInfo? {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
            url.deletingPathExtension().lastPathComponent
        return ExcludedAppInfo(bundleIdentifier: bundleIdentifier, name: name)
    }
}
