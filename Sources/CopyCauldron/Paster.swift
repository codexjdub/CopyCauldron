import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Simulates ⌘V into the currently-frontmost app. Requires Accessibility
/// permission (System Settings → Privacy & Security → Accessibility).
enum Paster {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user for Accessibility permission. Returns the trust state
    /// after the prompt (the system shows a dialog but doesn't block).
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Posts a synthetic ⌘V to the system after a short delay (so the popover
    /// has time to close and focus to return to the previous app). Returns
    /// `false` immediately if Accessibility permission is missing.
    @discardableResult
    static func pasteAfterDelay(_ delay: TimeInterval = 0.15) -> Bool {
        guard isTrusted() else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postPaste()
        }
        return true
    }

    private static func postPaste() {
        // `.privateState` so our synthesized event doesn't pick up the user's
        // currently-held modifiers (Shift in particular) at the HID level.
        let source = CGEventSource(stateID: .privateState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        down?.post(tap: loc)
        up?.post(tap: loc)
    }
}
