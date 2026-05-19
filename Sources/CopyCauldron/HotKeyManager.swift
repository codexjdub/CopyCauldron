import Foundation
import AppKit
import Carbon.HIToolbox

/// Wraps Carbon's `RegisterEventHotKey` so we can listen for a single global
/// hotkey without requesting Accessibility permission.
///
/// One instance owns one slot (one keyboard combo). Multiple instances can
/// coexist — the Carbon event handler installed by each one inspects the
/// `EventHotKeyID` on every press and only fires its own `onPress` when the
/// (signature, id) pair matches the instance that registered it. That's how
/// we run two managers side-by-side: one for the main panel hotkey, one for
/// the quick-switcher HUD.
@MainActor
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// 'CPYH' by default; callers can pass a different signature if they want
    /// fully separate handlers. The (signature, id) pair must be unique
    /// across instances or the C callback's filter won't distinguish them.
    let signature: OSType
    let id: UInt32
    var onPress: (() -> Void)?

    init(signature: OSType = 0x43505948 /* 'CPYH' */, id: UInt32 = 1) {
        self.signature = signature
        self.id = id
        installHandler()
    }

    deinit {
        if let h = eventHandler { RemoveEventHandler(h) }
        if let k = hotKeyRef    { UnregisterEventHotKey(k) }
    }

    func register(_ hotKey: HotKey) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("CopyCauldron: RegisterEventHotKey failed (status=\(status))")
        }
    }

    func unregister() {
        if let k = hotKeyRef {
            UnregisterEventHotKey(k)
            hotKeyRef = nil
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                // Read the hotkey id from the event so a manager only fires
                // for its own (signature, id) pair — otherwise every
                // installed handler would invoke its `onPress` on every
                // press of any registered hotkey.
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr else { return noErr }
                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == manager.signature,
                      hotKeyID.id == manager.id else {
                    // Carbon event handlers form a LIFO stack: returning
                    // `noErr` here would tell Carbon "I handled this" and
                    // *stop* dispatch, swallowing the event before the next
                    // manager's handler can see it. Use `eventNotHandledErr`
                    // so the dispatch continues down the stack and the
                    // manager whose (signature, id) actually matches gets
                    // its onPress called.
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    manager.onPress?()
                }
                return noErr
            },
            1,
            &spec,
            ctx,
            &eventHandler
        )
    }
}
