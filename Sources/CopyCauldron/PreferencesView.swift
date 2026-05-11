import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Open clipboard:") {
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
                    if preferences.openOnHover {
                        Text("The popover will open automatically when you hover the menu bar icon. Click outside to dismiss.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-paste on selection", isOn: $preferences.autoPaste)
                    if preferences.autoPaste {
                        Text(Paster.isTrusted()
                             ? "Selecting an item will paste it into the previously active app. Press 1–9 in the popover to paste a pinned item."
                             : "Auto-paste needs Accessibility permission. Open System Settings → Privacy & Security → Accessibility, enable CopyCauldron, then relaunch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Always paste as plain text", isOn: $preferences.pastePlainTextOnly)
                    if preferences.pastePlainTextOnly {
                        Text("Rich-text formatting (fonts, colors) captured from the source will be stripped before pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
            } header: {
                Text("History")
            } footer: {
                Text("Pinned items are kept across the history limit and survive Clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
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
