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
    var openReview: (() -> Void)?
    var openGallery: ((String, Bool) -> Void)?
    private static let testPanel = AwayPanel()
    var openDashboard: (() -> Void)?

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
    /// The block the timer is running now (focus, life or break), for the coach's day record.
    var inProgress: WorkSession? { timer.currentInProgressSession ?? timer.currentInProgressBreak }

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
        case "coach": Task { @MainActor in CoachChatWindow.shared.open() }
        case "coach-day":
            // focus://coach-day?date=2026-10-15 writes (or rewrites) that day's record now.
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            if let day = param("date").flatMap(f.date(from:)) {
                Task { @MainActor in CoachDayWorker.shared.ensure(day, force: true) }
            }
        case "review": openReview?()
        case "gallery":
            Task { @MainActor in
                DesignGallery.virtual = param("virtual") == "1"
                openGallery?(param("view") ?? "popover-0", param("dark") == "1")
            }
        case "gallery-close": Task { @MainActor in DesignGallery.closeAll(keepDisplay: param("display") != "0") }
        case "screen-debug": Task { @MainActor in ScreenWatcher.shared.dumpDebug() }
        case "test-card":
            // A real corner card whose answers only go to sync.log, to check the ⌃⌥⌘ keys.
            let m = AwayPromptModel(icon: "eye", title: "Test card", subtitle: "nothing changes", question: "",
                                    keep: "Keep", options: ["Math"], tags: tags)
            m.onPick = { _ in SyncLog.event("testCard", ["answer": "pick"]); Self.testPanel.dismiss() }
            m.onKeep = { SyncLog.event("testCard", ["answer": "keep"]); Self.testPanel.dismiss() }
            Self.testPanel.show(m)
        case "test-card-close": Self.testPanel.dismiss()
        case "dashboard": openDashboard?()
        case "log":
            // focus://log?label=HW&from=<unix>&to=<unix> relabels that range (label=Break for a break).
            guard let from = param("from").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                  let to = param("to").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                  to > from, to <= Date().addingTimeInterval(60), let raw = param("label") else { return }
            let label = raw.caseInsensitiveCompare("Break") == .orderedSame ? nil
                : tags.first { $0.caseInsensitiveCompare(raw) == .orderedSame } ?? raw
            timer.sessionStore?.paint(start: from, end: to, label: label)
            toast.show(icon: "pencil", title: "Logged \(label ?? "Break")",
                       detail: "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))")
        case "set-end":
            // focus://set-end?id=<session UUID>&end=<unix seconds>: end one
            // saved block at that time (repairs, through the app so it syncs).
            guard let id = param("id").flatMap(UUID.init(uuidString:)),
                  let end = param("end").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                  timer.sessionStore?.setEnd(id: id, end: end) == true else { return }
            toast.show(icon: "scissors", title: "Block shortened", detail: "")
        case "unlog":
            // focus://unlog?id=<session UUID> deletes one saved session.
            guard let id = param("id").flatMap(UUID.init(uuidString:)) else { return }
            timer.sessionStore?.delete(id: id)
            toast.show(icon: "trash", title: "Session removed", detail: "")
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

/// Spotlight-style: type to filter ("ma" ↩ → Math), ↑↓ to move, ↩ to run,
/// Esc to close. Also "break 15", "stop", "dashboard", "recall", "end day".
private struct SwitcherView: View {
    let quick: QuickSwitch
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let title: String
        var detail: String = ""
        let color: Color?
        var icon: String? = nil
        var hint: String = ""
        var current = false
        let run: () -> Void
        var id: String { title }
    }

    private var allItems: [Item] {
        var out: [Item] = quick.tags.enumerated().map { i, tag in
            Item(title: tag, detail: FocusCategories.isWellbeing(tag) ? "wellbeing" : (FocusCategories.isLife(tag) ? "life" : "focus"), color: categoryColor(tag),
                 hint: i < QuickSwitch.categoryKeys.count ? "⌃⌥⌘\(String(QuickSwitch.categoryKeys[i].key).uppercased())" : "",
                 current: tag == quick.currentLabel) { quick.switchTo(tag) }
        }
        let minutes = query.split(separator: " ").dropFirst().first.flatMap { Double($0) }
        out.append(Item(title: "Break", detail: minutes.map { "\(Int($0)) min" } ?? "counts up", color: TimerView.breakBlue,
                        icon: "cup.and.saucer", hint: "⌃⌥⌘L", current: quick.isOnBreak) { quick.startBreak(minutes: minutes) })
        if quick.isActive {
            out.append(Item(title: "Stop", detail: "saves what's running", color: nil, icon: "stop.fill", hint: "⌃⌥⌘0") { quick.stop() })
        }
        out.append(Item(title: "Dashboard", color: nil, icon: "rectangle.grid.2x2") { quick.openDashboard?() })
        out.append(Item(title: "Recall", color: nil, icon: "brain.head.profile", hint: "⌃⌥⌘;") { quick.openRecall?() })
        out.append(Item(title: "Ask Focus", color: nil, icon: "bubble.left.and.text.bubble.right") {
            Task { @MainActor in CoachChatWindow.shared.open() }
        })
        out.append(Item(title: "End day", detail: "review", color: nil, icon: "moon") { quick.openReview?() })
        return out
    }

    /// Prefix beats word-prefix beats letters in order ("sw" → SWE, "eday" → End day).
    private var items: [Item] {
        let q = (query.split(separator: " ").first.map(String.init) ?? "").lowercased()
        guard !q.isEmpty else { return allItems }
        func score(_ t: String) -> Int? {
            let s = t.lowercased()
            if s.hasPrefix(q) { return 0 }
            if s.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            var idx = s.startIndex
            for ch in q {
                guard let f = s[idx...].firstIndex(of: ch) else { return nil }
                idx = s.index(after: f)
            }
            return 2
        }
        return allItems.compactMap { i in score(i.title).map { (i, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    var body: some View {
        let list = items
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(Color.secondaryText)
                TextField(statusLine, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { if let i = list[safe: selection] { run(i.run) } }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { n, item in
                            row(item, selected: n == selection).id(n)
                                .onTapGesture { run(item.run) }
                        }
                        if list.isEmpty {
                            Text("No match").font(.system(size: 13)).foregroundStyle(Color.secondaryText).padding(14)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, n in proxy.scrollTo(n) }
            }
            .frame(height: 320)
        }
        .frame(width: 440)
        .modifier(FloatingPanelGlass())
        .onAppear { focused = true }
    }

    private var statusLine: String {
        if quick.isOnBreak { return "On a break · switch to…" }
        if !quick.currentLabel.isEmpty { return "\(quick.currentLabel) now · switch to…" }
        return "Start…"
    }

    private func run(_ action: @escaping () -> Void) {
        dismiss()
        action()
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if let c = item.color { Circle().fill(c).frame(width: 12, height: 12) }
                if let icon = item.icon, item.color == nil {
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
            }
            .frame(width: 20)
            Text(item.title).font(.system(size: 15, weight: item.current ? .semibold : .regular))
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            if item.current { Text("now").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText) }
            Spacer()
            Text(item.hint).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
    }
}

private struct FloatingPanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

final class FocusAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { QuickSwitch.shared?.handle(url: url) }
    }
}
