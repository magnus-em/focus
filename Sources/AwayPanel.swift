import SwiftUI
import AppKit
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
        guard settings.awayPrompts, !panel.isBusy, !(ScreenCoach.shared?.isBusy ?? false) else { return }
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

    // MARK: - Nothing running

    private func checkIdle() {
        let now = Date()
        let cal = Calendar.current
        guard settings.idleNudge, days.isDayStarted, !timer.isActive, !monitor.isAway, !panel.isBusy,
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
final class AwayPanel {
    private var panel: NSPanel?
    private var host: NSHostingController<AwayPromptView>?
    private var model: AwayPromptModel?
    private var expire: DispatchWorkItem?
    private static let width: CGFloat = 340

    var isBusy: Bool { panel != nil }

    func show(_ m: AwayPromptModel) {
        dismiss()
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

        let work = DispatchWorkItem { [weak self] in
            guard let self, let m = self.model, !m.touched else { return }
            self.dismiss()
        }
        expire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 * 60, execute: work)
    }

    private func layout() {
        guard let p = panel, let h = host, let screen = NSScreen.main?.visibleFrame else { return }
        h.view.layoutSubtreeIfNeeded()
        let height = h.view.fittingSize.height
        p.setFrame(NSRect(x: screen.maxX - Self.width - 16, y: screen.maxY - height - 12,
                          width: Self.width, height: height), display: true)
    }

    func dismiss() {
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: model.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 12, weight: .semibold))
                    Text(model.subtitle)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { if let keep = model.onKeep { keep() } else { model.onClose?() } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(model.keep.map { "\($0) — change nothing" } ?? "Dismiss")
            }

            Text(model.question)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 5) {
                if let keep = model.keep {
                    chip(keep, color: .secondary, primary: true) { model.onKeep?() }
                }
                ForEach(Array(model.options.enumerated()), id: \.offset) { _, o in
                    chip(o ?? "Break", color: o.map(categoryColor) ?? breakColor, primary: false) { model.onPick?(o) }
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
                    .buttonStyle(.plain)
                }
            }

            if let end = model.endTitle {
                Button(end) { model.onEnd?() }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(13)
        .frame(width: 340, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func chip(_ title: String, color: Color, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .font(.system(size: 11, weight: primary ? .semibold : .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(primary ? 0.22 : 0.15)))
            .foregroundStyle(primary ? Color.primary : color)
            .buttonStyle(.plain)
    }
}
