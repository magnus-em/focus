import SwiftUI
import AppKit
import Carbon
import FocusCore

/// Decides when to ask about time away from the Mac and when to nudge
/// because nothing is running. Every prompt defaults to changing nothing.
final class AwayCoach {
    static var shared: AwayCoach?

    private let monitor = PresenceMonitor.shared
    private let timer: TimerManager
    private let store: SessionStore
    private let settings: AppSettings
    private let days: DayStore
    private let panel = AwayPanel()
    private var nudgeTimer: Timer?

    /// Block (by start) whose idle-only away the user already said to keep.
    private var keepIdleFor: Date?
    private var lastNudge = Date.distantPast
    private var nudgesOffDay: Date?

    var isBusy: Bool { panel.isBusy }

    init(timer: TimerManager, store: SessionStore, settings: AppSettings, days: DayStore) {
        self.timer = timer
        self.store = store
        self.settings = settings
        self.days = days
        monitor.onReturn = { [weak self] span in
            // Let peer commands (phone switched while away) land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.handleReturn(span) }
        }
        monitor.start()
        // After the power-log backfill, so a night the app slept through counts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.applyOvernightSleep() }
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    private func fmt(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(mn)m"
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private func spansNight(_ span: AwaySpan) -> Bool {
        let cal = Calendar.current
        var t = span.start
        while t < span.end {
            if (1...5).contains(cal.component(.hour, from: t)) { return true }
            t.addTimeInterval(1800)
        }
        return false
    }

    // MARK: - Away

    private func handleReturn(_ span: AwaySpan) {
        if applyOvernightSleep() { return }
        guard settings.awayPrompts, !panel.isBusy, !(ScreenCoach.shared?.isBusy ?? false), !LeetCodeSolveDraftStore.isShowing else { return }
        let minMinutes = Double(settings.awayPromptMinutes)
        let overnight = span.minutes >= 180 && spansNight(span)

        if timer.isRunning, let blockStart = timer.sessionStartTime,
           blockStart <= span.start.addingTimeInterval(60) {
            let name = timer.isOnBreak ? "Break" : (timer.currentLabel.isEmpty ? "Focus" : timer.currentLabel)
            if timer.isFocusRunning {
                guard span.minutes >= minMinutes else { return }
                if span.reason == "idle", keepIdleFor == blockStart { return }
            } else {
                // Away is the point of most life blocks; only ask when the
                // block looks forgotten.
                guard name != "Sleep", span.reason != "idle", span.minutes >= 90 || overnight else { return }
            }
            let a = max(span.start, blockStart), b = span.end
            let gap = TimeGap(start: a, end: b)
            let keepLabel: String? = timer.isOnBreak ? nil : name
            var options = store.suggestions(for: gap, tags: settings.tags).filter { $0 != keepLabel }
            if !options.contains(where: { $0 == nil }), !timer.isOnBreak { options.append(nil) }

            let m = AwayPromptModel(
                icon: overnight ? "moon.zzz" : "figure.walk.arrival",
                title: "Away \(fmt(span.minutes))",
                subtitle: "\(clock(a)) – \(clock(b)) · \(name) kept running",
                question: overnight ? "Looks like a night. What was this time?" : "What was this time?",
                keep: "Still \(name)",
                options: options, tags: settings.tags
            )
            m.onKeep = { [weak self] in
                if span.reason == "idle" { self?.keepIdleFor = blockStart }
                self?.panel.dismiss()
            }
            m.onPick = { [weak self] label in
                guard let self else { return }
                if self.timer.isRunning, self.timer.sessionStartTime == blockStart {
                    self.timer.carveOut(from: a, to: b, as: label)
                } else {
                    self.store.paint(start: a, end: b, label: label)
                }
                self.panel.dismiss()
            }
            m.endTitle = "End \(name) at \(clock(a))"
            m.onEnd = { [weak self] in
                guard let self else { return }
                if self.timer.sessionStartTime == blockStart { self.timer.stop(at: a) }
                self.panel.dismiss()
            }
            panel.show(m)
            return
        }

        guard !timer.isActive, days.isDayStarted, span.minutes >= minMinutes else { return }
        guard let gap = store.untrackedGaps(from: span.start, to: span.end, minMinutes: minMinutes)
            .max(by: { $0.minutes < $1.minutes }) else { return }
        var options = store.suggestions(for: gap, tags: settings.tags)
        if !options.contains(where: { $0 == nil }) { options.append(nil) }
        let m = AwayPromptModel(
            icon: overnight ? "moon.zzz" : "figure.walk.arrival",
            title: "Away \(fmt(gap.minutes))",
            subtitle: "\(clock(gap.start)) – \(clock(gap.end)) · nothing was tracked",
            question: "What was this time?",
            keep: nil, options: options, tags: settings.tags
        )
        m.onPick = { [weak self] label in
            self?.store.fill(start: gap.start, end: gap.end, label: label)
            self?.panel.dismiss()
        }
        panel.show(m)
    }

    // MARK: - Overnight

    private static let sleptNightsKey = "overnightSleepNights"
    private static let sleptSinceKey = "overnightSleepSince"

    /// Turns the night part of any non-Sleep block into Sleep (`OvernightSleep`),
    /// then shows what changed with Undo. Each night is handled once, so an
    /// undone night stays undone. True when something changed.
    @discardableResult
    private func applyOvernightSleep() -> Bool {
        guard settings.autoSleepOvernight else { return false }
        let now = Date()
        let from = now.addingTimeInterval(-36 * 3600)
        let ud = UserDefaults.standard
        // [start, end] pairs: the power-log backfill can move a night's edges.
        var handled = (ud.array(forKey: Self.sleptNightsKey) as? [[Double]] ?? [])
            .filter { $0.count == 2 && $0[1] > from.addingTimeInterval(-86400).timeIntervalSince1970 }

        // Nights before the feature first ran stay as they were logged.
        if ud.object(forKey: Self.sleptSinceKey) == nil { ud.set(now.timeIntervalSince1970, forKey: Self.sleptSinceKey) }
        let since = max(from, Date(timeIntervalSince1970: ud.double(forKey: Self.sleptSinceKey)))
        let away = monitor.spans.filter { $0.end > since }.map { DateInterval(start: $0.start, end: $0.end) }
        // iPhone/iPad use (app opens, screen-notes blocks) wakes you.
        let activity = MainActor.assumeIsolated {
            ScreenWatcher.shared.activities(from: from, to: now)
                .filter { $0.device != nil }
                .map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
        }
        var blocks = store.sessions.compactMap { s -> OvernightSleep.Block? in
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            guard end > from else { return nil }
            return .init(start: s.startTime, end: end, label: s.type.isBreak ? nil : s.label)
        }
        if timer.isRunning, let start = timer.sessionStartTime {
            blocks.append(.init(start: start, end: now, label: timer.isOnBreak ? nil : timer.currentLabel, running: true))
        }
        let fixes = OvernightSleep.fixes(away: away, activity: activity, blocks: blocks, now: now)
            .filter { f in !handled.contains { $0[0] < f.night.end.timeIntervalSince1970 && $0[1] > f.night.start.timeIntervalSince1970 } }
        guard !fixes.isEmpty else { return false }
        for night in Set(fixes.map(\.night)) {
            handled.append([night.start.timeIntervalSince1970, night.end.timeIntervalSince1970])
        }
        ud.set(handled, forKey: Self.sleptNightsKey)

        var applied: [OvernightSleep.Fix] = []
        var undos: [SessionStore.ReviewUndo] = []
        for fix in fixes where !fix.running {
            if let u = store.paintForReview(start: fix.start, end: fix.end, label: "Sleep") {
                undos.append(u)
                applied.append(fix)
            }
        }
        if let fix = fixes.first(where: \.running), timer.isRunning, let start = timer.sessionStartTime, fix.start >= start {
            timer.carveOut(from: fix.start, to: fix.end, as: "Sleep")
            applied.append(fix)
        }
        let iso = ISO8601DateFormatter()
        SyncLog.event("autoSleepOvernight", [
            "fixes": fixes.map { "\($0.label ?? "Break") \(iso.string(from: $0.start))–\(iso.string(from: $0.end))\($0.running ? " running" : "")" },
            "applied": applied.count,
        ])
        guard let first = applied.min(by: { $0.start < $1.start }), let last = applied.max(by: { $0.end < $1.end }) else { return false }
        AwayPanel.dismissAll()
        showSlept(applied, from: first.start, to: last.end, undos: undos)
        return true
    }

    private func showSlept(_ fixes: [OvernightSleep.Fix], from: Date, to: Date, undos: [SessionStore.ReviewUndo]) {
        guard !(ScreenCoach.shared?.isBusy ?? false), !LeetCodeSolveDraftStore.isShowing else { return }
        var names: [String] = []
        for f in fixes { let n = f.label ?? "Break"; if !names.contains(n) { names.append(n) } }
        let running = fixes.first(where: \.running)
        let resume = running?.label
        var options: [String?] = []
        if running != nil || !timer.isActive {
            options = store.suggestions(for: TimeGap(start: to, end: to.addingTimeInterval(60)), tags: settings.tags)
                .filter { $0 != "Sleep" && $0 != resume }
            options = Array(options.prefix(3))
        }
        let m = AwayPromptModel(
            icon: "moon.zzz",
            title: "Logged your night as Sleep",
            subtitle: "\(clock(from)) – \(clock(to)) · \(names.joined(separator: ", ")) was running",
            question: options.isEmpty ? "No Mac, iPhone or iPad use all that time." : "What are you doing now?",
            keep: running != nil && resume != nil ? "Still \(resume!)" : "OK",
            options: options, tags: settings.tags.filter { $0 != "Sleep" }
        )
        m.onKeep = { [weak self] in self?.panel.dismiss() }
        m.onPick = { [weak self] label in
            guard let self else { return }
            let at = self.timer.sessionStartTime.map { max($0, to) } ?? to
            if let label { self.timer.switchTo(label, at: at) } else { self.timer.startManualBreak(minutes: 0, at: at) }
            self.panel.dismiss()
        }
        m.endTitle = "Undo"
        m.onEnd = { [weak self] in
            guard let self else { return }
            for u in undos.reversed() { _ = self.store.undoReview(u) }
            if let running {
                _ = self.store.paintForReview(start: running.start, end: running.end, label: running.label)
            }
            SyncLog.event("autoSleepOvernightUndo", ["from": "\(from)", "to": "\(to)"])
            self.panel.dismiss()
        }
        panel.show(m)
    }

    // MARK: - Nothing running

    private func checkIdle() {
        let now = Date()
        let cal = Calendar.current
        guard settings.idleNudge, days.isDayStarted, !timer.isActive, !monitor.isAway, !panel.isBusy, !LeetCodeSolveDraftStore.isShowing,
              !(ScreenCoach.shared?.isBusy ?? false),
              now.timeIntervalSince(lastNudge) >= 20 * 60,
              nudgesOffDay.map({ !cal.isDateInToday($0) }) ?? true else { return }

        let dayStart = days.todayRecord?.dayStart ?? cal.startOfDay(for: now)
        let lastEnd = store.sessions
            .map { $0.startTime.addingTimeInterval($0.durationMinutes * 60) }
            .filter { $0 <= now }
            .max() ?? dayStart
        // Time before you sat down is the away prompt's job, not this one.
        let since = max(lastEnd, dayStart, monitor.presentSince)
        guard now.timeIntervalSince(since) >= 10 * 60 else { return }
        lastNudge = now

        var options: [String?] = []
        if !timer.currentLabel.isEmpty { options.append(timer.currentLabel) }
        for s in store.suggestions(for: TimeGap(start: now.addingTimeInterval(-60), end: now), tags: settings.tags)
        where !options.contains(where: { $0 == s }) { options.append(s) }
        if !options.contains(where: { $0 == nil }) { options.append(nil) }

        let m = AwayPromptModel(
            icon: "circle.dashed",
            title: "Nothing's running",
            subtitle: "At the Mac since \(clock(since)) · \(fmt(now.timeIntervalSince(since) / 60)) untracked",
            question: "What are you doing? Starts from \(clock(since)).",
            keep: nil, options: Array(options.prefix(4)), tags: settings.tags
        )
        m.onPick = { [weak self] label in
            guard let self else { return }
            if let label { self.timer.switchTo(label, at: since) } else { self.timer.startManualBreak(minutes: 0, at: since) }
            self.panel.dismiss()
        }
        m.endTitle = "Not today"
        m.onEnd = { [weak self] in
            self?.nudgesOffDay = Date()
            self?.panel.dismiss()
        }
        panel.show(m)
    }
}

// MARK: - Panel

final class AwayPromptModel: ObservableObject {
    let icon: String
    let title: String
    let subtitle: String
    let question: String
    /// "Still SWE": leave the block as it is.
    let keep: String?
    let options: [String?]
    let tags: [String]
    var endTitle: String?

    @Published var showAll = false
    var onKeep: (() -> Void)?
    var onPick: ((String?) -> Void)?
    var onEnd: (() -> Void)?
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?
    var touched = false

    /// The first suggestion, as the ↩ shortcut takes it.
    var acceptTitle: String? { options.first.map { $0 ?? "Break" } }

    func accept() {
        guard let first = options.first else { return }
        onPick?(first)
    }

    func dismissCard() {
        if let onKeep { onKeep() } else { onClose?() }
    }

    init(icon: String, title: String, subtitle: String, question: String, keep: String?, options: [String?], tags: [String]) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.question = question
        self.keep = keep
        self.options = options
        self.tags = tags
    }
}

private final class AwayKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Corner card, same footprint as the recall prompt. Never takes focus.
/// While one shows, ⌃⌥⌘↩ takes its first suggestion and ⌃⌥⌘⌫ dismisses it
/// (same as ✕), from any app; registered only while a card is up. Once you
/// click the card, plain ↩ and Esc do the same.
final class AwayPanel {
    // Screen and away coaches each own a panel; the keys act on the newest
    // card still up and stay registered until the last one closes.
    private static var shown: [AwayPanel] = []
    private static var visible: AwayPanel? { shown.last }
    private static var keys: [GlobalHotKey] = []
    private var panel: NSPanel?
    private var host: NSHostingController<AwayPromptView>?
    private var model: AwayPromptModel?
    private var expire: DispatchWorkItem?
    private static let width: CGFloat = 340

    private var placedOn: NSScreen?
    var isBusy: Bool { panel != nil }

    func show(_ m: AwayPromptModel) {
        dismiss()
        placedOn = nil
        m.onClose = { [weak self] in self?.dismiss() }
        m.onResize = { [weak self] in DispatchQueue.main.async { self?.layout() } }
        model = m
        let h = NSHostingController(rootView: AwayPromptView(model: m))
        host = h
        let p = AwayKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        p.contentViewController = h
        h.view.focusRingType = .none
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        layout()
        p.orderFrontRegardless()
        Self.shown.append(self)
        Self.registerKeys()

        let work = DispatchWorkItem { [weak self] in
            guard let self, let m = self.model, !m.touched else { return }
            self.dismiss()
        }
        expire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60, execute: work)
    }

    private func layout() {
        // The screen you're on when the card appears, kept while it's up so a
        // resize doesn't jump it. NSScreen.main follows the key window, which
        // put cards on the other monitor (10/18).
        if placedOn == nil { placedOn = NSScreen.underMouse }
        guard let p = panel, let h = host, let screen = placedOn?.visibleFrame else { return }
        h.view.layoutSubtreeIfNeeded()
        let height = h.view.fittingSize.height
        p.setFrame(NSRect(x: screen.maxX - Self.width - 16, y: screen.maxY - height - 12,
                          width: Self.width, height: height), display: true)
    }

    private static func registerKeys() {
        guard keys.isEmpty else { return }
        let mods = GlobalHotKey.controlModifier | GlobalHotKey.optionModifier | GlobalHotKey.commandModifier
        let accept = GlobalHotKey(keyCode: UInt32(kVK_Return), modifiers: mods) {
            SyncLog.event("cardKey", ["key": "return", "card": AwayPanel.visible?.model?.title ?? "none"])
            AwayPanel.visible?.model?.accept()
        }
        let close = GlobalHotKey(keyCode: UInt32(kVK_Delete), modifiers: mods) {
            SyncLog.event("cardKey", ["key": "delete", "card": AwayPanel.visible?.model?.title ?? "none"])
            AwayPanel.visible?.model?.dismissCard()
        }
        keys = [accept, close].compactMap { $0 }
        SyncLog.event("cardKeysRegistered", ["count": keys.count])
    }

    /// Picking a category anywhere answers whatever a card was asking.
    static func dismissAll() {
        for p in shown.reversed() { p.dismiss() }
    }

    func dismiss() {
        Self.shown.removeAll { $0 === self }
        if Self.shown.isEmpty { Self.keys = [] }
        expire?.cancel()
        expire = nil
        panel?.close()
        panel = nil
        host = nil
        model = nil
    }
}

struct AwayPromptView: View {
    @ObservedObject var model: AwayPromptModel
    private let breakColor = Color(red: 0.27, green: 0.62, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 14, weight: .semibold))
                    Text(model.subtitle)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button { model.dismissCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help((model.keep.map { "\($0) — change nothing" } ?? "Dismiss") + " (⌃⌥⌘⌫)")
                .accessibilityLabel("Dismiss")
            }

            if !model.question.isEmpty {
                Text(model.question)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowLayout(spacing: 6) {
                if let keep = model.keep {
                    chip(keep, color: .secondary, primary: true) { model.onKeep?() }
                }
                ForEach(Array(model.options.enumerated()), id: \.offset) { i, o in
                    chip(o ?? "Break", color: o.map(categoryColor) ?? breakColor, primary: false, isDefault: i == 0) { model.onPick?(o) }
                }
                if model.showAll {
                    ForEach(model.tags.filter { t in !model.options.contains { $0 == t } && model.keep != "Still \(t)" }, id: \.self) { t in
                        chip(t, color: categoryColor(t), primary: false) { model.onPick?(t) }
                    }
                } else {
                    Button("More…") {
                        model.touched = true
                        model.showAll = true
                        model.onResize?()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .buttonStyle(.plain)
                }
            }

            if let end = model.endTitle {
                Button(end) { model.onEnd?() }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .buttonStyle(.plain)
            }

            if let accept = model.acceptTitle {
                Text("⌃⌥⌘↩ \(accept)  ·  ⌃⌥⌘⌫ \(model.keep ?? "Dismiss")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .topLeading)
        .modifier(CornerGlass())
        .focusEffectDisabled()
    }

    /// The suggested category's color, else orange for "needs you".
    private var tint: Color {
        if let first = model.options.first { return first.map(categoryColor) ?? breakColor }
        return .orange
    }

    private func chip(_ title: String, color: Color, primary: Bool, isDefault: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !primary { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(primary ? Color.primary.opacity(0.1) : color.opacity(0.2)))
            .contentShape(Capsule())
        }
        .font(.system(size: 13, weight: primary ? .semibold : .medium))
        .foregroundStyle(Color.primary)
        .buttonStyle(.plain)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}

/// Corner cards float over your work: one glass layer, Live Activity corners.
private struct CornerGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial).clipShape(shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
