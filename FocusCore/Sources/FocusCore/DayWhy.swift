import Foundation

/// Why a day had little focus, from plain comparisons with the four weeks
/// before it: when focus started, how long the night was, what took the time
/// instead, time nobody logged, how broken up the focus was and what the
/// screen showed during it. No model; every line says what it's compared with.
public enum DayWhy {
    /// One screen span: which window was in front and what it was labeled.
    public struct Window: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var app: String
        public var title: String
        public var category: String?

        public init(start: Date, end: Date, app: String, title: String, category: String?) {
            self.start = start
            self.end = end
            self.app = app
            self.title = title
            self.category = category
        }
    }

    public struct Reason: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case lateStart, sleep, category, untracked, fragmented, drift
        }

        public var kind: Kind
        public var title: String
        public var detail: String?
        /// Roughly how much focus time this explains, for ordering.
        public var minutes: Double
        public var category: String?
        /// Where on the day it happened, so the page can point at it.
        public var ranges: [DateInterval]

        public var id: String { "\(kind.rawValue)|\(category ?? "")" }
    }

    public struct Report: Equatable, Sendable {
        public var focusMinutes: Double
        /// Median focus over the compared days, when there were enough of them.
        public var usualMinutes: Double?
        public var comparedDays: Int
        public var reasons: [Reason]
        /// Short of the goal, or well short of the usual: worth explaining.
        public var light: Bool
    }

    /// Days with less than this tracked say nothing about what's usual.
    static let meaningfulMinutes = 120.0
    static let minimumDays = 5

    public static func report(day: Date, now: Date, tracked: [DayStory.Tracked], focus: Set<String>, goalMinutes: Double,
                              screen: [DayStory.Screen] = [], windows: [Window] = [], away: [DateInterval] = [],
                              compareDays: Int = 28, calendar: Calendar = .current) -> Report {
        let dayStart = calendar.startOfDay(for: day)
        let today = stats(dayStart, tracked: tracked, focus: focus, now: now, calendar: calendar)
        var history: [Stats] = []
        for back in 1...compareDays {
            guard let d = calendar.date(byAdding: .day, value: -back, to: dayStart) else { continue }
            let s = stats(d, tracked: tracked, focus: focus, now: now, calendar: calendar)
            if s.tracked >= meaningfulMinutes { history.append(s) }
        }
        let enough = history.count >= minimumDays
        let usualFocus = enough ? median(history.map(\.focus)) : nil
        let isToday = calendar.isDate(dayStart, inSameDayAs: now)
        let light = !isToday && (today.focus < goalMinutes || usualFocus.map { today.focus < $0 * 0.75 } ?? false)

        var reasons: [Reason] = []
        func places(_ ranges: [DateInterval]) -> String? {
            let top = topPlaces(windows, in: ranges)
            return top.isEmpty ? nil : top.map { "\($0.name) \(durationText(minutes: $0.minutes))" }.joined(separator: ", ")
        }

        if enough {
            if let first = today.firstFocus, let usual = median(history.compactMap(\.firstFocus)), first - usual >= 90 {
                var detail = "Usually around \(clock(usual, dayStart, calendar))."
                if let wake = today.wake, let usualWake = median(history.compactMap(\.wake)), wake - usualWake >= 60 {
                    detail += " You woke at \(clock(wake, dayStart, calendar)), usually \(clock(usualWake, dayStart, calendar))."
                }
                reasons.append(Reason(kind: .lateStart, title: "Focus started at \(clock(first, dayStart, calendar))",
                                      detail: detail, minutes: min(first - usual, 240), category: nil,
                                      ranges: [DateInterval(start: dayStart.addingTimeInterval(usual * 60),
                                                            end: dayStart.addingTimeInterval(first * 60))]))
            }
            let usualSleep = median(history.map(\.sleep)) ?? 0
            if usualSleep > 0, today.sleep - usualSleep >= 90 {
                reasons.append(Reason(kind: .sleep, title: "Slept \(durationText(minutes: today.sleep))",
                                      detail: "Usually \(durationText(minutes: usualSleep)).",
                                      minutes: today.sleep - usualSleep, category: "Sleep", ranges: today.sleepRanges))
            }
        }

        // An average day, not the median: Class or Exercise on two days in
        // five has a median of zero, and "usually none" read wrong (11/9).
        let labels = Set(today.byLabel.keys).subtracting(focus).subtracting(["Sleep"])
        for label in labels.sorted() {
            let minutes = today.byLabel[label] ?? 0
            let ranges = today.ranges[label] ?? []
            let usual = enough ? history.reduce(0.0) { $0 + ($1.byLabel[label] ?? 0) } / Double(history.count) : nil
            let extra = minutes - (usual ?? 0)
            guard usual == nil ? minutes >= 60 : extra >= 45 else { continue }
            var detail = usual.map { $0 < 5 ? "Usually almost none." : "About \(durationText(minutes: $0)) on an average day." } ?? ""
            if let seen = places(ranges) { detail += (detail.isEmpty ? "" : " ") + "On screen: \(seen)." }
            reasons.append(Reason(kind: .category, title: "\(label == "Break" ? "Breaks" : label): \(durationText(minutes: minutes))",
                                  detail: detail.isEmpty ? nil : detail, minutes: extra, category: label, ranges: ranges))
        }

        let usualGap = enough ? median(history.map(\.untracked)) ?? 0 : 0
        if today.untracked - usualGap >= 45 {
            var detail = !enough ? "" : usualGap < 5 ? "Usually you log everything between your first and last block."
                : "Usually \(durationText(minutes: usualGap)) goes unlogged."
            let awayMinutes = today.gaps.reduce(0.0) { sum, g in
                sum + away.reduce(0.0) { $0 + overlap($1, g) } / 60
            }
            if awayMinutes >= today.untracked * 0.6 {
                detail += (detail.isEmpty ? "" : " ") + "You were away from your Mac for most of it."
            } else if let seen = places(today.gaps) {
                detail += (detail.isEmpty ? "" : " ") + "On screen: \(seen)."
            }
            reasons.append(Reason(kind: .untracked, title: "Nothing logged for \(durationText(minutes: today.untracked))",
                                  detail: detail.isEmpty ? nil : detail, minutes: today.untracked - usualGap,
                                  category: nil, ranges: today.gaps))
        }

        if enough, today.focus >= 60, today.focusRanges.count >= 3, let usualLongest = median(history.filter { $0.focus >= 20 }.map(\.longestFocus)),
           usualLongest >= 40, today.longestFocus <= usualLongest / 2 {
            let usualBlocks = median(history.map { Double($0.blocks) }) ?? 0
            reasons.append(Reason(kind: .fragmented, title: "Focus came in short pieces",
                                  detail: "Longest stretch \(durationText(minutes: today.longestFocus)), usually \(durationText(minutes: usualLongest)). "
                                      + "\(today.blocks) blocks logged, usually \(Int(usualBlocks.rounded())).",
                                  minutes: (usualLongest - today.longestFocus) / 2, category: nil, ranges: []))
        }

        var drift: [String: (minutes: Double, ranges: [DateInterval])] = [:]
        for f in today.focusRanges {
            for s in screen where !s.uncertain {
                guard let c = s.category, !focus.contains(c) else { continue }
                let a = max(s.start, f.start), b = min(s.end, f.end)
                guard b > a else { continue }
                drift[c, default: (0, [])].minutes += b.timeIntervalSince(a) / 60
                drift[c, default: (0, [])].ranges.append(DateInterval(start: a, end: b))
            }
        }
        let driftMinutes = drift.values.reduce(0) { $0 + $1.minutes }
        if driftMinutes >= 20, let top = drift.max(by: { $0.value.minutes < $1.value.minutes }) {
            let ranges = drift.values.flatMap(\.ranges)
            reasons.append(Reason(kind: .drift,
                                  title: "During focus, the screen showed \(top.key) for \(durationText(minutes: top.value.minutes))",
                                  detail: places(ranges).map { "On screen: \($0)." },
                                  minutes: driftMinutes, category: top.key, ranges: ranges))
        }

        reasons.sort { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.id < $1.id }
        return Report(focusMinutes: today.focus, usualMinutes: usualFocus, comparedDays: history.count,
                      reasons: Array(reasons.prefix(5)), light: light)
    }

    // MARK: Per-day numbers

    struct Stats {
        var tracked = 0.0
        var focus = 0.0
        /// Minutes after midnight.
        var firstFocus: Double?
        var wake: Double?
        var sleep = 0.0
        var sleepRanges: [DateInterval] = []
        var byLabel: [String: Double] = [:]
        var ranges: [String: [DateInterval]] = [:]
        var focusRanges: [DateInterval] = []
        var untracked = 0.0
        var gaps: [DateInterval] = []
        var longestFocus = 0.0
        var blocks = 0
    }

    static func stats(_ dayStart: Date, tracked: [DayStory.Tracked], focus: Set<String>, now: Date,
                      calendar: Calendar) -> Stats {
        var s = Stats()
        let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart)!, now)
        guard dayEnd > dayStart else { return s }
        let night = (dayStart.addingTimeInterval(-6 * 3600), dayStart.addingTimeInterval(14 * 3600))
        var clipped: [(Date, Date, String)] = []
        for t in tracked {
            if t.label == "Sleep" {
                let a = max(t.start, night.0), b = min(t.end, night.1, now)
                if b > a {
                    s.sleep += b.timeIntervalSince(a) / 60
                    s.sleepRanges.append(DateInterval(start: a, end: b))
                }
                if t.end.timeIntervalSince(t.start) >= 2 * 3600, t.end > dayStart,
                   t.end < dayStart.addingTimeInterval(15 * 3600) {
                    let w = t.end.timeIntervalSince(dayStart) / 60
                    s.wake = max(s.wake ?? 0, w)
                }
            }
            let a = max(t.start, dayStart), b = min(t.end, dayEnd)
            guard b > a else { continue }
            clipped.append((a, b, t.label))
        }
        clipped.sort { $0.0 < $1.0 }
        for (a, b, label) in clipped {
            let minutes = b.timeIntervalSince(a) / 60
            s.tracked += minutes
            s.byLabel[label, default: 0] += minutes
            s.ranges[label, default: []].append(DateInterval(start: a, end: b))
            if label != "Sleep" { s.blocks += 1 }
            if focus.contains(label) {
                s.focus += minutes
                let m = a.timeIntervalSince(dayStart) / 60
                s.firstFocus = min(s.firstFocus ?? m, m)
                s.focusRanges.append(DateInterval(start: a, end: b))
            }
        }
        var merged: [(Date, Date)] = []
        for (a, b, _) in clipped {
            if let last = merged.last, a <= last.1 { merged[merged.count - 1].1 = max(last.1, b) } else { merged.append((a, b)) }
        }
        for (x, y) in zip(merged, merged.dropFirst()) where y.0.timeIntervalSince(x.1) >= 5 * 60 {
            s.gaps.append(DateInterval(start: x.1, end: y.0))
            s.untracked += y.0.timeIntervalSince(x.1) / 60
        }
        var run: (Date, Date)?
        for f in s.focusRanges {
            if let r = run, f.start.timeIntervalSince(r.1) <= 120 {
                run = (r.0, max(r.1, f.end))
            } else {
                run = (f.start, f.end)
            }
            s.longestFocus = max(s.longestFocus, run!.1.timeIntervalSince(run!.0) / 60)
        }
        return s
    }

    // MARK: Screen

    private static let browsers: Set<String> = ["Google Chrome", "Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge",
                                                "Brave Browser", "Orion", "Dia"]

    /// A site for browser windows ("Video – YouTube" → YouTube, "(17) Home / X" → X), else the app.
    public static func place(_ w: Window) -> String {
        guard browsers.contains(w.app) else { return w.app }
        for sep in [" - ", " – ", " — ", " | ", " / ", " · "] where w.title.contains(sep) {
            let last = w.title.components(separatedBy: sep).last!.trimmingCharacters(in: .whitespaces)
            if (1...24).contains(last.count) { return last }
        }
        let title = w.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? w.app : String(title.prefix(32))
    }

    static func topPlaces(_ windows: [Window], in ranges: [DateInterval], limit: Int = 3) -> [(name: String, minutes: Double)] {
        guard !ranges.isEmpty else { return [] }
        var minutes: [String: Double] = [:]
        for w in windows {
            let span = DateInterval(start: w.start, end: max(w.end, w.start))
            let m = ranges.reduce(0.0) { $0 + overlap(span, $1) } / 60
            if m > 0 { minutes[place(w), default: 0] += m }
        }
        return minutes.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { (name: $0.key, minutes: $0.value) }
    }

    // MARK: Helpers

    static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    static func clock(_ minutes: Double, _ dayStart: Date, _ calendar: Calendar) -> String {
        let total = Int((minutes / 5).rounded()) * 5
        let h = (total / 60) % 24, m = total % 60
        let hour = h % 12 == 0 ? 12 : h % 12
        return m == 0 ? "\(hour) \(h < 12 ? "AM" : "PM")" : "\(hour):\(m < 10 ? "0" : "")\(m) \(h < 12 ? "AM" : "PM")"
    }
}
