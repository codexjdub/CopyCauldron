import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Compact 4-row HUD-style overlay shown by the secondary hotkey (default
/// `⌘⌥V`). Surfaces just the most recent unpinned items so the common case
/// of "give me the thing I just copied" is a single-keystroke pick. Press
/// `1`–`4` to paste; `Esc` dismisses without pasting. Holding `Shift` while
/// pressing a number inverts the plain-text-paste preference for that one
/// paste, matching the main panel's behavior.
struct QuickSwitcherView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var preferences: Preferences
    /// Called when the user picks an item. The second argument is `true`
    /// when `Shift` was held — used to invert plain-text-only mode for
    /// that one paste.
    let onActivate: (ClipboardItem, Bool) -> Void
    let onClose: () -> Void

    @State private var keyMonitor: Any?
    @State private var recentItems: [ClipboardItem] = []

    var body: some View {
        VStack(spacing: 2) {
            if recentItems.isEmpty {
                Text("No recent items")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                    QuickSwitcherRow(
                        item: item,
                        shortcut: "\(index + 1)",
                        onTap: { shiftHeld in
                            onActivate(item, shiftHeld)
                        }
                    )
                }
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .onAppear {
            refreshItems(from: store.items)
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onReceive(store.$items) { newItems in
            // Pulls from the closure parameter, not `store.items` — same
            // `@Published`-willSet gotcha as PanelView.
            refreshItems(from: newItems)
        }
        .onChange(of: preferences.quickSwitcherItemCount) { _ in
            // User bumped the row count from Preferences while the HUD
            // wasn't visible; refresh in case it ever shows back up
            // without a fresh `.onAppear` (rare, but cheap to handle).
            refreshItems(from: store.items)
        }
    }

    private func refreshItems(from items: [ClipboardItem]) {
        let count = preferences.quickSwitcherItemCount
        recentItems = Array(items.filter { !$0.isPinned }.prefix(count))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == kVK_Escape {
            onClose()
            return true
        }
        // `charactersIgnoringModifiers` keeps the digit visible even with
        // Shift held, so `Shift+1` still resolves to "1" — we then inspect
        // the modifier flags separately to decide whether to invert
        // plain-text mode for that paste.
        if let chars = event.charactersIgnoringModifiers,
           let n = Int(chars),
           n >= 1, n <= recentItems.count {
            let shiftHeld = event.modifierFlags.contains(.shift)
            onActivate(recentItems[n - 1], shiftHeld)
            return true
        }
        return false
    }
}

private struct QuickSwitcherRow: View {
    let item: ClipboardItem
    let shortcut: String
    let onTap: (_ shiftHeld: Bool) -> Void

    var body: some View {
        Button {
            // Capture the modifier state at click time so shift-click can
            // invert plain-text mode the same way it does in the panel.
            onTap(NSEvent.modifierFlags.contains(.shift))
        } label: {
            HStack(spacing: 10) {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                    )
                Text(item.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
