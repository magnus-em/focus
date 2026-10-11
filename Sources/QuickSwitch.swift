import AppKit
import Carbon.HIToolbox
import SwiftUI
import FocusCore

/// Every way to change what the timer is tracking without opening the
/// popover: global hotkeys, the ⌃⌥⌘J switcher panel, `focus://` URLs,
/// and commands arriving from other devices.
///
/// Hotkeys (all ⌃⌥⌘, right hand only): J switcher · K start/stop · L break ·
/// ; recall · 0 stop · Space pause. Categories take `categoryKeys` in order
/// (U I O P M , . / …), the same keys the switcher panel shows.
/// URLs: focus://switch/<category>, focus://stop,
/// focus://break[?minutes=N], focus://toggle, focus://switcher,
/// focus://recall
final class QuickSwitch {
    static var shared: QuickSwitch?

    private let timer: TimerManager
    private let settings: AppSettings
    private let days: DayStore
    private let toast = HotKeyToast()
    private var hotKeys: [GlobalHotKey] = []
    private lazy var switcher = SwitcherPanel(quick: self)
    var openRecall: (() -> Void)?

    /// Right-hand keys for categories, in `settings.tags` order.
    static let categoryKeys: [(key: Character, code: Int)] = [
        ("u", kVK_ANSI_U), ("i", kVK_ANSI_I), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
        ("m", kVK_ANSI_M), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
        ("y", kVK_ANSI_Y), ("h", kVK_ANSI_H), ("n", kVK_ANSI_N),
        ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9), ("6", kVK_ANSI_6),
        ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal),
    ]

    init(timer: TimerManager, settings: AppSettings, days: DayStore) {
        self.timer = timer
        self.settings = settings
        self.days = days

        let mods = GlobalHotKey.controlModifier | GlobalHotKey.optionModifier | GlobalHotKey.commandModifier
        func bind(_ key: UInt32, _ action: @escaping () -> Void) {
            if let hk = GlobalHotKey(keyCode: key, modifiers: mods, handler: action) { hotKeys.append(hk) }
        }
        bind(UInt32(kVK_Space)) { [weak timer] in timer?.toggleRunPause() }
        bind(UInt32(kVK_ANSI_J)) { [weak self] in self?.showSwitcher() }
        bind(UInt32(kVK_ANSI_K)) { [weak self] in self?.toggle() }
        bind(UInt32(kVK_ANSI_L)) { [weak self] in self?.startBreak() }
        bind(UInt32(kVK_ANSI_Semicolon)) { [weak self] in self?.openRecall?() }
        bind(UInt32(kVK_ANSI_0)) { [weak self] in self?.stop() }
        for (i, k) in Self.categoryKeys.enumerated() {
            bind(UInt32(k.code)) { [weak self] in
                guard let self, i < self.settings.tags.count else { return }
                self.switchTo(self.settings.tags[i])
            }
        }

        timer.onCommandApplied = { [weak self] cmd in
            guard let self else { return }
            self.ensureDayOpen()
            switch cmd.action {
            case .switchTo: self.toast.show(icon: "iphone", title: "Switched to \(cmd.label)", detail: "from another device")
            case .stop: self.toast.show(icon: "iphone", title: "Stopped", detail: "from another device")
            case .startBreak: self.toast.show(icon: "iphone", title: "Break started", detail: "from another device")
            }
        }
    }

    var tags: [String] { settings.tags }
    var currentLabel: String { timer.isActive && !timer.isOnBreak ? timer.currentLabel : "" }
    var isActive: Bool { timer.isActive }
    var isOnBreak: Bool { timer.isOnBreak && timer.isActive }

    private func ensureDayOpen() {
        if !days.isDayStarted { days.isDayEnded ? days.reopenDay() : days.startDay() }
    }

    func switchTo(_ label: String) {
        let previous = currentLabel
        ensureDayOpen()
        timer.switchTo(label)
        toast.show(icon: "arrow.triangle.swap",
                   title: label,
                   detail: previous.isEmpty || previous == label ? "Focus started" : "from \(previous)")
    }

    func toggle() {
        ensureDayOpen()
        switch timer.quickToggle(tag: settings.quickStartTag) {
        case .started(let label):
            toast.show(icon: "play.fill", title: "Focus started",
                       detail: [label, timer.timeString].filter { !$0.isEmpty }.joined(separator: " · "))
        case .stopped(let minutes, let label):
            toast.show(icon: "stop.fill",
                       title: minutes >= 1 ? "Saved \(minutes)m" : "Stopped (under 1m, not saved)",
                       detail: label)
        }
    }

    func stop() {
        guard timer.isActive else { return }
        let label = timer.isOnBreak ? "Break" : timer.currentLabel
        timer.reset()
        toast.show(icon: "stop.fill", title: "Stopped", detail: label)
    }

    func startBreak(minutes: Double? = nil) {
        timer.startManualBreak(minutes: minutes ?? 0)
        toast.show(icon: "cup.and.saucer.fill", title: "Break", detail: minutes.map { "\(Int($0))m" } ?? "counting up")
    }

    func showSwitcher() { switcher.show() }

    func handle(url: URL) {
        // focustracker:// is the old scheme, kept so existing shortcuts still work.
        guard url.scheme == "focus" || url.scheme == "focustracker" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param: (String) -> String? = { name in query.first { $0.name == name }?.value }
        let pathArg = url.pathComponents.dropFirst().first
        switch url.host?.lowercased() {
        case "switch", "start":
            let requested = pathArg ?? param("to") ?? param("category") ?? settings.quickStartTag
            let label = tags.first { $0.caseInsensitiveCompare(requested) == .orderedSame } ?? requested
            switchTo(label)
        case "stop": stop()
        case "break": startBreak(minutes: param("minutes").flatMap(Double.init))
        case "toggle": toggle()
        case "switcher": showSwitcher()
        case "recall": openRecall?()
        default: break
        }
    }
}

// MARK: - Switcher panel

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class SwitcherPanel {
    private weak var quick: QuickSwitch?
    private var panel: KeyPanel?
    private var previousApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

    init(quick: QuickSwitch) { self.quick = quick }

    func show() {
        guard let quick else { return }
        if panel != nil { close(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let view = SwitcherView(quick: quick) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let p = KeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.contentView = hosting
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = true
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY + 80))
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in self?.close(restoreFocus: false) }
    }

    func close(restoreFocus: Bool = true) {
        guard let p = panel else { return }
        panel = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        p.close()
        if restoreFocus, let prev = previousApp, prev != NSRunningApplication.current {
            prev.activate()
        }
    }
}

private struct SwitcherView: View {
    let quick: QuickSwitch
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    private let accent = Color(red: 0.96, green: 0.36, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(Array(quick.tags.enumerated()), id: \.offset) { i, tag in
                row(key: i < QuickSwitch.categoryKeys.count ? String(QuickSwitch.categoryKeys[i].key).uppercased() : "·",
                    title: tag, current: tag == quick.currentLabel) { quick.switchTo(tag) }
            }
            Divider().padding(.vertical, 4)
            row(key: "L", title: "Break", current: quick.isOnBreak) { quick.startBreak() }
            if quick.isActive {
                row(key: "0", title: "Stop", current: false) { quick.stop() }
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            let c = press.characters.lowercased()
            if press.key == .escape { dismiss(); return .handled }
            if c == "0" || c == "k" { run { quick.stop() }; return .handled }
            if c == "l" { run { quick.startBreak() }; return .handled }
            if c == "j" { dismiss(); return .handled }
            if let ch = c.first, let i = QuickSwitch.categoryKeys.firstIndex(where: { $0.key == ch }), i < quick.tags.count {
                run { quick.switchTo(quick.tags[i]) }
                return .handled
            }
            return .ignored
        }
    }

    private var statusLine: String {
        if quick.isOnBreak { return "On a break" }
        if !quick.currentLabel.isEmpty { return "Now: \(quick.currentLabel)" }
        return quick.isActive ? "Focus (no category)" : "Idle — pick what you're doing"
    }

    private func run(_ action: @escaping () -> Void) {
        dismiss()
        action()
    }

    private func row(key: String, title: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 10) {
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                Text(title).font(.system(size: 13, weight: current ? .semibold : .regular))
                Spacer()
                if current { Circle().fill(accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

final class FocusAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { QuickSwitch.shared?.handle(url: url) }
    }
}
