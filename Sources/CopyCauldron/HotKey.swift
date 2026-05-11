import Foundation
import AppKit
import Carbon.HIToolbox

struct HotKey: Codable, Equatable {
    /// Virtual key code (e.g. kVK_ANSI_V == 9).
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    static let defaultHotKey = HotKey(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyCodeToString(keyCode)
        return s
    }

    /// Build from NSEvent (used by the hotkey recorder).
    static func from(event: NSEvent) -> HotKey? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if mods.contains(.command)  { carbon |= UInt32(cmdKey) }
        if mods.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if mods.contains(.option)   { carbon |= UInt32(optionKey) }
        if mods.contains(.control)  { carbon |= UInt32(controlKey) }
        guard carbon != 0 else { return nil }   // require at least one modifier
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    private static func keyCodeToString(_ code: UInt32) -> String {
        // Special keys first.
        switch Int(code) {
        case kVK_Return:        return "↩"
        case kVK_Tab:            return "⇥"
        case kVK_Space:          return "Space"
        case kVK_Delete:         return "⌫"
        case kVK_Escape:         return "⎋"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_UpArrow:        return "↑"
        case kVK_DownArrow:      return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2"
        case kVK_F3:  return "F3";  case kVK_F4:  return "F4"
        case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8"
        case kVK_F9:  return "F9";  case kVK_F10: return "F10"
        case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: break
        }

        // General case: ask the keyboard layout.
        guard let layoutData = TISGetInputSourceProperty(
                TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
                kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let cfData = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(cfData),
                                      to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let status = UCKeyTranslate(
            keyLayout,
            UInt16(code),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        guard status == noErr, actualLength > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: actualLength).uppercased()
    }
}
