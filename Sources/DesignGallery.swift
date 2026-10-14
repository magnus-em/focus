import AppKit
import SwiftUI
import VirtualDisplay

/// `focus://gallery?view=popover-0&dark=1[&virtual=1]` opens one screen in a
/// plain window (real compositor, so Liquid Glass renders, unlike offscreen
/// snapshot renderers) for `scripts/shots.sh` to screenshot.
/// `focus://gallery-close[?display=0]`.
///
/// With `virtual=1` the window goes on a display that exists only in
/// WindowServer, placed diagonally off the corner of your real screens, so
/// screenshots can be taken while you work. Glass renders there because it's
/// a real display; windows behind the desktop on your own screen don't.
@MainActor
enum DesignGallery {
    private static var windows: [NSWindow] = []
    static var virtual = false

    static func show<V: View>(_ view: V, name: String, dark: Bool, size: NSSize) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Gallery \(name) \(dark ? "dark" : "light")"
        w.styleMask = [.titled, .closable]
        w.setContentSize(size)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        windows.append(w)
        guard virtual else {
            w.center()
            // Only from scripts/shots.sh while you're away from the Mac.
            w.orderFrontRegardless()
            return
        }
        Task {
            guard let screen = await VirtualScreen.screen() else { return }
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: max(f.minY, f.maxY - w.frame.height - 20)))
            w.orderFrontRegardless()
        }
    }

    static func closeAll(keepDisplay: Bool = true) {
        windows.forEach { $0.close() }
        windows.removeAll()
        if keepDisplay { VirtualScreen.releaseSoon() } else { VirtualScreen.release() }
    }
}

@MainActor
enum VirtualScreen {
    private static var display: FocusVirtualDisplay?
    private static var releaseTask: Task<Void, Never>?
    static let size = (width: 1600, height: 1100)

    static func screen() async -> NSScreen? {
        releaseTask?.cancel()
        if display == nil {
            display = FocusVirtualDisplay(name: "Focus Gallery", width: UInt(size.width), height: UInt(size.height))
            guard let display else { return nil }
            moveAway(display.displayID)
        }
        guard let id = display?.displayID else { return nil }
        for _ in 0..<40 {
            if let s = NSScreen.screens.first(where: { number($0) == id }) { return s }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Diagonal to the bottom-right corner of every real display: touching
    /// only at a corner, so the pointer doesn't wander onto it.
    private static func moveAway(_ id: CGDirectDisplayID) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let others = ids.prefix(Int(n)).filter { $0 != id }.map { CGDisplayBounds($0) }
        let maxX = others.map(\.maxX).max() ?? 0, maxY = others.map(\.maxY).max() ?? 0
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayOrigin(cfg, id, Int32(maxX), Int32(maxY))
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    private static func number(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func releaseSoon() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { release() }
        }
    }

    static func release() {
        releaseTask?.cancel()
        display = nil
    }
}
