import AppKit
import Combine
import FocusCore

/// The live count of study without a distraction (`FocusStreak.Live`), fed
/// once a second by `WindowTimelineRecorder` with what's in front and the
/// screen's label for it. Publishes whole minutes for the popover, and hands
/// a "back to it" card to `ScreenCoach` when a distraction ends a stretch
/// worth protecting. State in UserDefaults `focusStreak.live` so a relaunch
/// keeps today's best.
@MainActor
final class FocusStreakStore: ObservableObject {
    static let shared = FocusStreakStore()
    private static let key = "focusStreak.live"

    @Published private(set) var minutes = 0
    @Published private(set) var bestMinutes = 0
    @Published private(set) var focusing = false
    /// When the stretch running now began; nil when none is, or a distraction ended it.
    @Published private(set) var since: Date?
    /// The distraction that ended the last stretch, while it's still in front.
    @Published private(set) var away: (name: String, since: Date)?
    /// What the streak makes of the window in front right now, for the menu bar.
    @Published private(set) var reading: Reading?

    struct Reading: Equatable {
        /// nil: no label (not read yet, unsure, or a window that shows no task).
        var category: String?
        var detail: String
        var state: State = .labeled
        enum State { case labeled, unsure, unread }
    }

    private var live: FocusStreak.Live
    /// The app you were studying in, to go back to.
    private(set) var studyApp: NSRunningApplication?
    private var savedAt = Date.distantPast

    private init() {
        live = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode(FocusStreak.Live.self, from: $0) }
            ?? FocusStreak.Live()
    }

    func tick(front: WindowTimelineRecorder.Front?, now: Date = Date()) {
        let day = CoachDay.dayKey(now)
        var kind: FocusStreak.Kind?
        var seen: Reading?
        if let front, let block = ScreenCoach.shared?.focusBlock, !PresenceMonitor.shared.isAway {
            if front.bundle == ScreenWatcher.ownBundle {
                kind = .neutral
                // Opening the popover puts Focus in front; keep what you were on.
                seen = reading
            } else {
                let (category, source, sample) = label(for: front, now: now)
                seen = Self.reading(front, category: category, sample: sample)
                let life = Set(ScreenCoach.shared?.appSettings.lifeTags ?? []).union(["Leisure", "Admin", "Social", "Meals"])
                kind = FocusStreak.kind(app: front.app, bundle: front.bundle, title: front.title, url: front.url,
                                        category: category, labelSource: source, life: life.subtracting([block]))
            }
            if kind == .study, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == front.bundle {
                studyApp = app
            }
        }
        let event = live.tick(now, kind: kind, day: day)
        if seen != reading { reading = seen }
        focusing = kind != nil
        let m = Int(live.current(at: now) / 60), b = Int(live.best(at: now, day: day) / 60)
        if m != minutes { minutes = m }
        if b != bestMinutes { bestMinutes = b }
        let broken = live.brokeMinutes != nil
        let start = broken ? nil : live.streakStart
        if start != since { since = start }
        let gone = broken ? live.distractionStart.map { (name: live.distractionName ?? "Away", since: $0) } : nil
        if gone?.name != away?.name || gone?.since != away?.since { away = gone }
        switch event {
        case .broke(let name, let minutes):
            SyncLog.event("focusStreakBroke", ["by": name, "minutes": Int(minutes)])
            save()
        case .nudge(let name, let minutes):
            ScreenCoach.shared?.distractionNudge(name: name, minutes: minutes, best: live.best(at: now, day: day) / 60,
                                                 returnTo: studyApp)
        case .back:
            ScreenCoach.shared?.distractionEnded()
        case nil:
            if now.timeIntervalSince(savedAt) > 60 { save() }
        }
    }

    private func save() {
        savedAt = Date()
        if let data = try? JSONEncoder().encode(live) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// The screen's latest label for this window: the same title within 4 h,
    /// else whatever it last read in the same app in the last minute.
    private func label(for f: WindowTimelineRecorder.Front, now: Date) -> (String?, String?, ScreenSample?) {
        if ScreenWatcher.privateApps.contains(f.bundle) { return (WindowTimeline.privateCategory, nil, nil) }
        let samples = ScreenWatcher.shared.samples
        let match = f.title.flatMap { t in
            samples.last { $0.bundleID == f.bundle && $0.title == t && now.timeIntervalSince($0.date) < 4 * 3600 }
        } ?? samples.last.flatMap { $0.bundleID == f.bundle && now.timeIntervalSince($0.date) < 60 ? $0 : nil }
        guard let s = match, !s.uncertain else { return (nil, nil, match) }
        return (s.category, s.source, s)
    }

    private static func reading(_ f: WindowTimelineRecorder.Front, category: String?, sample: ScreenSample?) -> Reading {
        if category == WindowTimeline.privateCategory { return Reading(category: category, detail: f.app) }
        guard let s = sample else { return Reading(category: nil, detail: f.title ?? f.app, state: .unread) }
        var d = s.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.hasPrefix(s.app + ": ") { d = String(d.dropFirst(s.app.count + 2)) }
        if d.isEmpty || d == "Private" { d = s.title.isEmpty ? s.app : s.title }
        if d.hasSuffix(".") { d.removeLast() }
        return Reading(category: category, detail: d, state: s.uncertain ? .unsure : .labeled)
    }
}
