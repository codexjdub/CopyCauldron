import SwiftUI
import AppKit

/// Bridge that exposes the SwiftUI view's hosting `NSWindow` to surrounding
/// code. Drop into `.background()` and provide a closure that stashes the
/// window reference; callers then use that reference to scope behavior to
/// "events / actions targeted at this view's own window."
///
/// Why we need it: `NSEvent.addLocalMonitorForEvents` is **application-wide**,
/// so every view that installs a monitor sees every keyDown in the app —
/// including those meant for other windows. Comparing `event.window` to the
/// window captured here lets each monitor consume only its own events.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
