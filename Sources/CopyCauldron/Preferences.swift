import Foundation
import Combine
import SwiftUI
import AppKit

enum RetentionPeriod: String, CaseIterable, Codable, Identifiable {
    case off
    case oneHour
    case twentyFourHours
    case sevenDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:              return "Off"
        case .oneHour:          return "1 hour"
        case .twentyFourHours:  return "24 hours"
        case .sevenDays:        return "7 days"
        }
    }

    /// How long an unpinned item lives before the TTL sweep evicts it.
    /// `nil` means "never expire" (the `off` case).
    var seconds: TimeInterval? {
        switch self {
        case .off:              return nil
        case .oneHour:          return 3600
        case .twentyFourHours:  return 86_400
        case .sevenDays:        return 604_800
        }
    }
}

enum TextSize: String, CaseIterable, Codable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:      return "Small"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "XLarge"
        }
    }

    /// Multiplier applied to explicit point sizes (and SwiftUI semantic fonts
    /// rendered via `.system(size:)`) inside the panel. macOS's Dynamic Type
    /// support is weak, so we scale manually for a visible effect.
    var scaleFactor: CGFloat {
        switch self {
        case .small:      return 0.85
        case .medium:     return 1.0
        case .large:      return 1.20
        case .extraLarge: return 1.50
        }
    }
}

/// Short feedback sounds suitable for firing on every clipboard capture.
/// Curated from `/System/Library/Sounds` — long or alert-y system sounds
/// (Basso, Sosumi, Submarine, Purr) are intentionally excluded so a
/// rapid copy burst doesn't turn into an annoying loop.
enum CaptureSound: String, CaseIterable, Codable, Identifiable {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"
    case ping = "Ping"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Plays the sound at system alert volume. Safe to call on any
    /// thread; `NSSound.play()` enqueues onto AppKit's audio thread.
    /// Returns silently if the named sound isn't available.
    func play() {
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}

struct ExcludedAppInfo: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var name: String

    var id: String { bundleIdentifier }

    var displayName: String {
        name.isEmpty ? bundleIdentifier : name
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier the panel applies to explicit font sizes.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    private let hotKeyKey = "hotKey"
    private let quickSwitcherHotKeyKey = "quickSwitcherHotKey"
    private let quickSwitcherItemCountKey = "quickSwitcherItemCount"
    private let openOnHoverKey = "openOnHover"
    private let maxPinnedItemsKey = "maxPinnedItems"
    // Note: these UserDefaults string keys keep their historical names so
    // existing users don't lose their saved panel size/position.
    private let panelWidthKey = "popoverWidth"
    private let panelHeightKey = "popoverHeight"
    private let panelOriginXKey = "popoverOriginX"
    private let panelOriginYKey = "popoverOriginY"
    private let keepPanelOpenKey = "keepPanelOpen"
    private let autoPasteKey = "autoPaste"
    private let pastePlainTextOnlyKey = "pastePlainTextOnly"
    private let maxHistoryItemsKey = "maxHistoryItems"
    private let textSizeKey = "textSize"
    private let retentionPeriodKey = "retentionPeriod"
    private let excludedAppsKey = "excludedApps"
    private let captureSoundEnabledKey = "captureSoundEnabled"
    private let captureSoundKey = "captureSound"
    static let defaultMaxPinnedItems = 20
    static let pinnedItemsRange = 1...100
    static let defaultMaxHistoryItems = 50
    static let historyItemsRange = 10...500
    static let historyItemsStep = 1
    static let defaultQuickSwitcherItemCount = 4
    /// Capped at 9 because the quick switcher's whole appeal is one-key
    /// activation via the digit row — going higher breaks the gesture.
    static let quickSwitcherItemRange = 2...9
    static let defaultPanelSize = CGSize(width: 360, height: 480)
    static let minPanelSize = CGSize(width: 280, height: 320)
    static let maxPanelSize = CGSize(width: 700, height: 900)

    @Published var hotKey: HotKey {
        didSet { saveHotKey() }
    }

    @Published var quickSwitcherHotKey: HotKey {
        didSet { saveQuickSwitcherHotKey() }
    }

    @Published var quickSwitcherItemCount: Int {
        didSet { defaults.set(quickSwitcherItemCount, forKey: quickSwitcherItemCountKey) }
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

    @Published var keepPanelOpen: Bool {
        didSet { defaults.set(keepPanelOpen, forKey: keepPanelOpenKey) }
    }

    @Published var textSize: TextSize {
        didSet { defaults.set(textSize.rawValue, forKey: textSizeKey) }
    }

    @Published var retentionPeriod: RetentionPeriod {
        didSet { defaults.set(retentionPeriod.rawValue, forKey: retentionPeriodKey) }
    }

    @Published var excludedApps: [ExcludedAppInfo] {
        didSet { saveExcludedApps() }
    }

    /// When true, `ClipboardMonitor` plays `captureSound` after a new
    /// item is accepted into history. Off by default — unsolicited
    /// audio is the kind of thing that gets the app uninstalled.
    @Published var captureSoundEnabled: Bool {
        didSet { defaults.set(captureSoundEnabled, forKey: captureSoundEnabledKey) }
    }

    @Published var captureSound: CaptureSound {
        didSet { defaults.set(captureSound.rawValue, forKey: captureSoundKey) }
    }

    /// Persisted panel size (read at launch, written by drag-to-resize).
    var panelSize: CGSize {
        get {
            let w = defaults.double(forKey: panelWidthKey)
            let h = defaults.double(forKey: panelHeightKey)
            guard w > 0 && h > 0 else { return Self.defaultPanelSize }
            return CGSize(width: w, height: h)
        }
        set {
            defaults.set(newValue.width, forKey: panelWidthKey)
            defaults.set(newValue.height, forKey: panelHeightKey)
        }
    }

    /// Persisted floating panel position, in screen coordinates.
    var panelOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: panelOriginXKey) != nil,
                  defaults.object(forKey: panelOriginYKey) != nil else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: panelOriginXKey),
                y: defaults.double(forKey: panelOriginYKey)
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: panelOriginXKey)
                defaults.removeObject(forKey: panelOriginYKey)
                return
            }
            defaults.set(newValue.x, forKey: panelOriginXKey)
            defaults.set(newValue.y, forKey: panelOriginYKey)
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
        if let data = defaults.data(forKey: quickSwitcherHotKeyKey),
           let decoded = try? JSONDecoder().decode(HotKey.self, from: data) {
            self.quickSwitcherHotKey = decoded
        } else {
            self.quickSwitcherHotKey = .defaultQuickSwitcherHotKey
        }
        let storedQSCount = defaults.integer(forKey: quickSwitcherItemCountKey)
        // `defaults.integer` returns 0 when the key is missing; treat anything
        // outside the supported range as "use the default."
        self.quickSwitcherItemCount = Self.quickSwitcherItemRange.contains(storedQSCount)
            ? storedQSCount
            : Self.defaultQuickSwitcherItemCount
        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.openOnHover = defaults.bool(forKey: openOnHoverKey)
        let storedMax = defaults.integer(forKey: maxPinnedItemsKey)
        self.maxPinnedItems = storedMax > 0 ? storedMax : Self.defaultMaxPinnedItems
        let storedHistoryMax = defaults.integer(forKey: maxHistoryItemsKey)
        self.maxHistoryItems = storedHistoryMax > 0 ? storedHistoryMax : Self.defaultMaxHistoryItems
        self.autoPaste = defaults.bool(forKey: autoPasteKey)
        self.pastePlainTextOnly = defaults.bool(forKey: pastePlainTextOnlyKey)
        self.keepPanelOpen = defaults.bool(forKey: keepPanelOpenKey)
        let storedTextSize = defaults.string(forKey: textSizeKey).flatMap(TextSize.init(rawValue:))
        self.textSize = storedTextSize ?? .medium
        let storedRetention = defaults.string(forKey: retentionPeriodKey).flatMap(RetentionPeriod.init(rawValue:))
        self.retentionPeriod = storedRetention ?? .off
        if let data = defaults.data(forKey: excludedAppsKey),
           let decoded = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) {
            self.excludedApps = decoded
        } else {
            self.excludedApps = []
        }
        self.captureSoundEnabled = defaults.bool(forKey: captureSoundEnabledKey)
        let storedSound = defaults.string(forKey: captureSoundKey).flatMap(CaptureSound.init(rawValue:))
        self.captureSound = storedSound ?? .tink
    }

    func addExcludedApp(_ app: ExcludedAppInfo) {
        guard !app.bundleIdentifier.isEmpty else { return }
        var apps = excludedApps.filter { $0.bundleIdentifier != app.bundleIdentifier }
        apps.append(app)
        excludedApps = apps.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func removeExcludedApps(bundleIdentifiers: Set<String>) {
        guard !bundleIdentifiers.isEmpty else { return }
        excludedApps.removeAll { bundleIdentifiers.contains($0.bundleIdentifier) }
    }

    func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func saveHotKey() {
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: hotKeyKey)
        }
    }

    private func saveQuickSwitcherHotKey() {
        if let data = try? JSONEncoder().encode(quickSwitcherHotKey) {
            defaults.set(data, forKey: quickSwitcherHotKeyKey)
        }
    }

    private func saveExcludedApps() {
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: excludedAppsKey)
        }
    }
}
