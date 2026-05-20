import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Compact HUD-style overlay shown by the secondary hotkey (default
/// `⌘⌥V`). Surfaces just the most recent unpinned items so the common case
/// of "give me the thing I just copied" is a single-keystroke pick. Press
/// `1`–`N` to paste; `Esc` dismisses without pasting. Holding `Shift` while
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

    @State private var recentItems: [ClipboardItem] = []
    @State private var selectedID: UUID?

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
                        isSelected: item.id == selectedID,
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
        .windowScopedKeyMonitor { event in handleKey(event) }
        // SwiftUI's idiomatic Esc handler. Belt-and-suspenders alongside
        // the local NSEvent monitor installed by `windowScopedKeyMonitor`.
        .onExitCommand { onClose() }
        .onAppear {
            refreshItems(from: store.items)
        }
        .onReceive(store.$items) { newItems in
            refreshItems(from: newItems)
        }
        .onChange(of: preferences.quickSwitcherItemCount) { _ in
            refreshItems(from: store.items)
        }
    }

    private func refreshItems(from items: [ClipboardItem]) {
        let count = preferences.quickSwitcherItemCount
        recentItems = Array(items.filter { !$0.isPinned }.prefix(count))
        // Keep the current selection if it still exists in the visible
        // window; otherwise select the first row so Return / arrow keys
        // have something to act on.
        if selectedID == nil || !recentItems.contains(where: { $0.id == selectedID }) {
            selectedID = recentItems.first?.id
        }
    }

    /// Returns true when the event has been consumed. Monitor lifecycle,
    /// window scoping, digit-key mapping, and selection movement are all
    /// owned by the shared keyboard-navigation helpers.
    private func handleKey(_ event: NSEvent) -> Bool {
        let shiftHeld = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Escape:
            onClose()
            return true
        case kVK_DownArrow:
            selectedID = Selection.adjacentID(in: recentItems, from: selectedID, by: 1)
            return true
        case kVK_UpArrow:
            selectedID = Selection.adjacentID(in: recentItems, from: selectedID, by: -1)
            return true
        case kVK_Return:
            if let id = selectedID,
               let item = recentItems.first(where: { $0.id == id }) {
                onActivate(item, shiftHeld)
            }
            return true
        default:
            break
        }
        if let n = Keyboard.digitIndex(for: event),
           n >= 1, n <= recentItems.count {
            onActivate(recentItems[n - 1], shiftHeld)
            return true
        }
        return false
    }
}

private struct QuickSwitcherRow: View {
    let item: ClipboardItem
    let shortcut: String
    let isSelected: Bool
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
