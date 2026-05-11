import Foundation
import Combine

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let openOnHoverKey = "openOnHover"
    private let maxPinnedItemsKey = "maxPinnedItems"
    private let popoverWidthKey = "popoverWidth"
    private let popoverHeightKey = "popoverHeight"
    private let autoPasteKey = "autoPaste"
    private let pastePlainTextOnlyKey = "pastePlainTextOnly"
    private let maxHistoryItemsKey = "maxHistoryItems"
    static let defaultMaxPinnedItems = 20
    static let pinnedItemsRange = 1...100
    static let defaultMaxHistoryItems = 50
    static let historyItemsRange = 10...500
    static let historyItemsStep = 10
    static let defaultPopoverSize = CGSize(width: 360, height: 480)
    static let minPopoverSize = CGSize(width: 280, height: 320)
    static let maxPopoverSize = CGSize(width: 700, height: 900)

    @Published var hotKey: HotKey {
        didSet { saveHotKey() }
    }

    @Published var openOnHover: Bool {
        didSet { defaults.set(openOnHover, forKey: openOnHoverKey) }
    }

    @Published var maxPinnedItems: Int {
        didSet { defaults.set(maxPinnedItems, forKey: maxPinnedItemsKey) }
    }

    @Published var maxHistoryItems: Int {
        didSet { defaults.set(maxHistoryItems, forKey: maxHistoryItemsKey) }
    }

    @Published var autoPaste: Bool {
        didSet {
            defaults.set(autoPaste, forKey: autoPasteKey)
            if autoPaste && !Paster.isTrusted() {
                Paster.requestPermission()
            }
        }
    }

    @Published var pastePlainTextOnly: Bool {
        didSet { defaults.set(pastePlainTextOnly, forKey: pastePlainTextOnlyKey) }
    }

    /// Persisted popover size (read at launch, written by drag-to-resize).
    var popoverSize: CGSize {
        get {
            let w = defaults.double(forKey: popoverWidthKey)
            let h = defaults.double(forKey: popoverHeightKey)
            guard w > 0 && h > 0 else { return Self.defaultPopoverSize }
            return CGSize(width: w, height: h)
        }
        set {
            defaults.set(newValue.width, forKey: popoverWidthKey)
            defaults.set(newValue.height, forKey: popoverHeightKey)
        }
    }

    /// Mirrors `SMAppService.mainApp.status`. Updating this calls the system
    /// API; we then re-sync from the actual status so the UI reflects reality
    /// even if registration failed.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            let actual = LaunchAtLogin.setEnabled(launchAtLogin)
            if actual != launchAtLogin {
                isSyncingLaunchAtLogin = true
                launchAtLogin = actual
                isSyncingLaunchAtLogin = false
            }
        }
    }
    private var isSyncingLaunchAtLogin = false

    init() {
        if let data = defaults.data(forKey: hotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            self.hotKey = decoded
        } else {
            self.hotKey = .defaultHotKey
        }
        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.openOnHover = defaults.bool(forKey: openOnHoverKey)
        let storedMax = defaults.integer(forKey: maxPinnedItemsKey)
        self.maxPinnedItems = storedMax > 0 ? storedMax : Self.defaultMaxPinnedItems
        let storedHistoryMax = defaults.integer(forKey: maxHistoryItemsKey)
        self.maxHistoryItems = storedHistoryMax > 0 ? storedHistoryMax : Self.defaultMaxHistoryItems
        self.autoPaste = defaults.bool(forKey: autoPasteKey)
        self.pastePlainTextOnly = defaults.bool(forKey: pastePlainTextOnlyKey)
    }

    private func saveHotKey() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
    }
}
