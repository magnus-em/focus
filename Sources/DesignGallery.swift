import AppKit
import SwiftUI

/// `focus://gallery?view=popover-0&dark=1` opens one screen in a plain window
/// (real compositor, so Liquid Glass renders, unlike offscreen snapshot
/// renderers) for `scripts/shots.sh` to screenshot. `focus://gallery-close`.
@MainActor
enum DesignGallery {
    private static var windows: [NSWindow] = []

    static func show<V: View>(_ view: V, name: String, dark: Bool, size: NSSize) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Gallery \(name) \(dark ? "dark" : "light")"
        w.styleMask = [.titled, .closable]
        w.setContentSize(size)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.center()
        // In front, because glass only renders right over real content.
        // scripts/shots.sh runs only while you're away from the Mac.
        w.orderFrontRegardless()
        windows.append(w)
    }

    static func closeAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}
