import SwiftUI
import AppKit
import Combine

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    /// Refreshed on appear and on a 2s timer while the window is open
    /// so the banner disappears shortly after the user grants permission
    /// in System Settings — no need to relaunch the Preferences window.
    @State private var isAccessibilityTrusted: Bool = Paster.isTrusted()
    /// 2s `AXIsProcessTrusted` poll. Connectable (not `.autoconnect()`)
    /// so we can stop it on `.onDisappear`: the Preferences window is
    /// retained for the app's lifetime by its window controller, so an
    /// autoconnected timer would keep firing forever after the window
    /// closes. `.onAppear` re-connects it (and does a one-shot refresh,
    /// so status is always current on open even if reconnect no-ops).
    private let trustTimer = Timer.publish(every: 2, on: .main, in: .common)
    @State private var trustTimerConnection: Cancellable?

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Image(systemName: isAccessibilityTrusted
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(isAccessibilityTrusted ? .green : .orange)
                        Text(isAccessibilityTrusted ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                        Button("Open Settings") {
                            openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Required by some features below — look for the orange warning in the section header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Text size", selection: $preferences.textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            } header: {
                Text("Appearance & Startup")
            }

            Section {
                LabeledContent("Hotkey") {
                    HotKeyRecorder(hotKey: $preferences.hotKey)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-open on hover", isOn: $preferences.openOnHover)
                    Text("The panel opens automatically when you hover the menu-bar icon. Press ⎋ or click the X in the panel header to dismiss it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Main Panel")
            } footer: {
                Text("Press a key combo with at least one modifier (⌘ ⇧ ⌃ ⌥). Press ⎋ to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Hotkey") {
                    HotKeyRecorder(hotKey: $preferences.quickSwitcherHotKey)
                }
                Stepper(
                    "Items shown: \(preferences.quickSwitcherItemCount)",
                    value: $preferences.quickSwitcherItemCount,
                    in: Preferences.quickSwitcherItemRange
                )
            } header: {
                SectionHeader(
                    title: "Quick Switcher",
                    warning: isAccessibilityTrusted
                        ? nil
                        : "HUD positioning needs Accessibility"
                )
            } footer: {
                Text("A compact HUD pops near your cursor with your most recent unpinned items; press the digit or home-row letter (1/a, 2/s, …) to paste, Shift+key to invert plain-text mode, ⎋ to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Auto-paste on selection", isOn: $preferences.autoPaste)
                    .disabled(!isAccessibilityTrusted)
            } header: {
                SectionHeader(
                    title: "Paste",
                    warning: isAccessibilityTrusted
                        ? nil
                        : "Requires Accessibility"
                )
            } footer: {
                Text("Selecting an item pastes it into the previously active app. Pinned items also have keyboard shortcuts (1–9, then a–o, q–z) for direct paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Play sound on capture", isOn: $preferences.captureSoundEnabled)
                Picker("Sound", selection: $preferences.captureSound) {
                    ForEach(CaptureSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.captureSoundEnabled)
                // Preview the selection so the user knows what they're
                // picking without having to copy something to test.
                .onChange(of: preferences.captureSound) { newValue in
                    newValue.play()
                }
                ExcludedAppsControl(preferences: preferences)
            } header: {
                Text("Capture")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture sound is off by default and plays whenever a new item enters history.")
                    Text("Excluded apps: CopyCauldron skips every copied item whose source app is on this list. Browser extensions appear as their host browser.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Stepper(
                    "History size: \(preferences.maxHistoryItems)",
                    value: $preferences.maxHistoryItems,
                    in: Preferences.historyItemsRange,
                    step: Preferences.historyItemsStep
                )
                Stepper(
                    "Max pinned items: \(preferences.maxPinnedItems)",
                    value: $preferences.maxPinnedItems,
                    in: Preferences.pinnedItemsRange
                )
                Picker("Auto-expire after", selection: $preferences.retentionPeriod) {
                    ForEach(RetentionPeriod.allCases) { period in
                        Text(period.displayName).tag(period)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pinned items are exempt from the history limit, the Clear button, and auto-expire.")
                    Text("Auto-expire sweeps unpinned items past the chosen age at launch and every 60 minutes thereafter.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 920)
        .onAppear {
            refreshTrustStatus()
            trustTimerConnection = trustTimer.connect()
        }
        .onDisappear {
            trustTimerConnection?.cancel()
            trustTimerConnection = nil
        }
        .onReceive(trustTimer) { _ in refreshTrustStatus() }
    }

    private func refreshTrustStatus() {
        let current = Paster.isTrusted()
        if current != isAccessibilityTrusted {
            isAccessibilityTrusted = current
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Form section header that optionally trails the title with an orange
/// "requires Accessibility" / "needs Accessibility" warning pill. Used
/// to flag sections whose functionality is gated on (Paste) or degraded
/// without (Quick Switcher) Accessibility permission.
private struct SectionHeader: View {
    let title: String
    let warning: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            if let warning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}

private struct ExcludedAppsControl: View {
    @ObservedObject var preferences: Preferences
    @State private var selectedBundleIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preferences.excludedApps.isEmpty {
                Text("No excluded apps")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                List(selection: $selectedBundleIDs) {
                    ForEach(preferences.excludedApps) { app in
                        HStack(spacing: 8) {
                            ExcludedAppIcon(bundleIdentifier: app.bundleIdentifier)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                Text(app.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(app.bundleIdentifier)
                    }
                }
                .frame(height: 138)
            }

            HStack(spacing: 8) {
                Button {
                    chooseApps()
                } label: {
                    Label("Add App...", systemImage: "plus")
                }
                Button {
                    preferences.removeExcludedApps(bundleIdentifiers: selectedBundleIDs)
                    selectedBundleIDs = []
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedBundleIDs.isEmpty)
            }
            .buttonStyle(.bordered)
        }
        .onChange(of: preferences.excludedApps) { apps in
            let currentIDs = Set(apps.map(\.bundleIdentifier))
            selectedBundleIDs = selectedBundleIDs.intersection(currentIDs)
        }
    }

    private func chooseApps() {
        guard let urls = AppBundleResolver.chooseApplicationURLs() else { return }
        var addedBundleIDs: Set<String> = []
        for url in urls {
            if let bundleIdentifier = addApp(at: url) {
                addedBundleIDs.insert(bundleIdentifier)
            }
        }
        selectedBundleIDs = addedBundleIDs
    }

    private func addApp(at url: URL) -> String? {
        guard let app = AppBundleResolver.excludedAppInfo(at: url) else {
            presentInvalidAppAlert(url)
            return nil
        }
        preferences.addExcludedApp(app)
        return app.bundleIdentifier
    }

    private func presentInvalidAppAlert(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Can't Add App"
        alert.informativeText = "\(url.lastPathComponent) does not expose a bundle identifier."
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct ExcludedAppIcon: View {
    let bundleIdentifier: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear {
            icon = AppIconProvider.icon(
                bundleIdentifier: bundleIdentifier,
                size: NSSize(width: 24, height: 24)
            )
        }
    }
}

private struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            Text(isRecording ? "Press a key…" : hotKey.display)
                .frame(minWidth: 120)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cancel on Escape (with no modifiers).
            if event.keyCode == 53 && event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
                return nil
            }
            if let captured = HotKey.from(event: event) {
                hotKey = captured
                stopRecording()
                return nil
            }
            // Modifier-only or unsupported — swallow so the field stays focused.
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
