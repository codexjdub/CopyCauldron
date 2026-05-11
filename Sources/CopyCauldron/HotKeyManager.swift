import Foundation
import AppKit
import Carbon.HIToolbox

/// Wraps Carbon's RegisterEventHotKey so we can listen for a single global
/// hotkey without requesting Accessibility permission.
@MainActor
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentSignature: OSType = 0x43505948 // 'CPYH'
    private var currentID: UInt32 = 1
    var onPress: (() -> Void)?

    init() {
        installHandler()
    }

    deinit {
        if let h = eventHandler { RemoveEventHandler(h) }
        if let k = hotKeyRef    { UnregisterEventHotKey(k) }
    }

    func register(_ hotKey: HotKey) {
        unregister()
        let id = EventHotKeyID(signature: currentSignature, id: currentID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            id,
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
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
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
