import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (macOS 13+) for registering the
/// app to launch at login. Status is the source of truth — the user can also
/// change it from System Settings → General → Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state (after the system has applied the change),
    /// which may differ from `enabled` if the registration failed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("CopyCauldron: launch-at-login toggle failed: \(error)")
        }
        return service.status == .enabled
    }
}
