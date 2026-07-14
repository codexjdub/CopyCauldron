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
    private(set) var currentHotKey: HotKey?
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

    /// Registers a replacement without sacrificing the working shortcut on
    /// failure. Carbon rejects duplicate combinations within one process; if
    /// that or another error occurs, the previous registration is restored.
    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        if hotKeyRef != nil, currentHotKey == hotKey {
            return true
        }
        let previousHotKey = currentHotKey
        unregister()
        let status = installRegistration(hotKey)
        guard status == noErr else {
            NSLog("CopyCauldron: RegisterEventHotKey failed (status=\(status))")
            if let previousHotKey {
                let restoreStatus = installRegistration(previousHotKey)
                if restoreStatus != noErr {
                    NSLog("CopyCauldron: failed to restore previous hotkey (status=\(restoreStatus))")
                }
            }
            return false
        }
        return true
    }

    private func installRegistration(_ hotKey: HotKey) -> OSStatus {
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
            currentHotKey = hotKey
        }
        return status
    }

    func unregister() {
        if let k = hotKeyRef {
            UnregisterEventHotKey(k)
            hotKeyRef = nil
        }
        currentHotKey = nil
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

@MainActor
func presentHotKeyRegistrationFailure(attempted: HotKey, restored: HotKey?) {
    let alert = NSAlert()
    alert.messageText = "Shortcut Unavailable"
    if let restored {
        alert.informativeText = "CopyCauldron couldn't register \(attempted.display). It may already be assigned to the other CopyCauldron action. Your previous shortcut, \(restored.display), remains active."
    } else {
        alert.informativeText = "CopyCauldron couldn't register \(attempted.display). Choose a different key combination."
    }
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
