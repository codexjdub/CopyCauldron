import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HotKeyRecorder(hotKey: $preferences.hotKey)
                }
            } header: {
                Text("Global Shortcut")
            } footer: {
                Text("Press a key combo with at least one modifier (⌘ ⇧ ⌃ ⌥). Press ⎋ to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-open on hover", isOn: $preferences.openOnHover)
                    Text("The panel opens automatically when you hover the menu-bar icon. Press ⎋ or click the X in the panel header to dismiss it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-paste on selection", isOn: $preferences.autoPaste)
                    Text(Paster.isTrusted()
                         ? "Selecting an item pastes it into the previously active app. Pinned items also have keyboard shortcuts (1–9, then a–o, q–z) for direct paste."
                         : "Auto-paste needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility, enable CopyCauldron, then relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Text size", selection: $preferences.textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("General")
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
        .frame(width: 460, height: 650)
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
