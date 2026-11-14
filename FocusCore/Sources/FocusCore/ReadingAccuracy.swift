import Foundation

/// How well Focus reads the screen during focus, a day at a time, against
/// the bar in CATEGORIES.md for letting Focus name every block: the screen's
/// category matches the block (your corrections win) on 90% of the focus
/// time it labeled, no label on at most 5%, and at most 1 in 10 switches it
/// made without asking undone.
public enum ReadingAccuracy {
    public static let rightBar = 0.9
    public static let unlabeledBar = 0.05
    public static let undoneBar = 0.1

    /// One "Wrong?" answer, a line of `Focus/screen-corrections.jsonl`.
    public struct Correction: Codable, Equatable, Sendable {
        public var at: Date
        public var app: String
        public var bundle: String
        public var title: String
        /// Memory keys of every window that learned the answer.
        public var windows: [String]
        /// Those windows' readings from here until `at` were wrong.
        public var since: Date
        public var wasCategory: String?
        public var wasCourse: String?
        public var wasSource: String?
        public var toCategory: String?
        /// "" = not a class.
        public var toCourse: String?
        /// The running block, and what it was renamed to, when the answer renamed it.
        public var block: String?
        public var renamedTo: String?
        /// "popover", "hotkey" or "title menu".
        public var via: String

        public init(at: Date, app: String, bundle: String, title: String, windows: [String], since: Date,
                    wasCategory: String?, wasCourse: String?, wasSource: String?, toCategory: String?, toCourse: String?,
                    block: String?, renamedTo: String?, via: String) {
            self.at = at; self.app = app; self.bundle = bundle; self.title = title; self.windows = windows; self.since = since
            self.wasCategory = wasCategory; self.wasCourse = wasCourse; self.wasSource = wasSource
            self.toCategory = toCategory; self.toCourse = toCourse; self.block = block; self.renamedTo = renamedTo; self.via = via
        }
    }

    /// A screen reading (private apps and Focus itself left out by the caller).
    public struct Span: Sendable {
        public var start: Date, end: Date
        public var window: String
        public var category: String?
        public var uncertain: Bool

        public init(start: Date, end: Date, window: String, category: String?, uncertain: Bool) {
            self.start = start; self.end = end; self.window = window; self.category = category; self.uncertain = uncertain
        }
    }

    /// A focus block on the timer (not Class: in class the screen names the subject by design).
    public struct Block: Sendable {
        public var start: Date, end: Date
        public var label: String

        public init(start: Date, end: Date, label: String) {
            self.start = start; self.end = end; self.label = label
        }
    }

    public struct AutoSwitch: Sendable {
        public var at: Date
        public var undone: Bool

        public init(at: Date, undone: Bool) {
            self.at = at; self.undone = undone
        }
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public var day: Date
        public var readSeconds: Double = 0
        public var labeledSeconds: Double = 0
        public var rightSeconds: Double = 0
        public var autoSwitches = 0
        public var undone = 0
        public var corrections = 0
        public var courseCorrections = 0
        public var id: Date { day }

        public init(day: Date) { self.day = day }

        public var right: Double? { labeledSeconds >= 60 ? rightSeconds / labeledSeconds : nil }
        public var unlabeled: Double? { readSeconds >= 60 ? (readSeconds - labeledSeconds) / readSeconds : nil }
        public var undoneShare: Double? { autoSwitches > 0 ? Double(undone) / Double(autoSwitches) : nil }

        /// Every measure with data clears its bar.
        public var meetsBar: Bool? {
            let checks = [right.map { $0 >= ReadingAccuracy.rightBar }, unlabeled.map { $0 <= ReadingAccuracy.unlabeledBar },
                          undoneShare.map { $0 <= ReadingAccuracy.undoneBar }].compactMap { $0 }
            return checks.isEmpty ? nil : checks.allSatisfy { $0 }
        }
    }

    public static func days(spans: [Span], blocks: [Block], corrections: [Correction], autoSwitches: [AutoSwitch],
                            from: Date, to: Date, calendar: Calendar = .current) -> [Day] {
        var out: [Date: Day] = [:]
        var d = calendar.startOfDay(for: from)
        while d < to {
            out[d] = Day(day: d)
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? to
        }
        func key(_ t: Date) -> Date? {
            let k = calendar.startOfDay(for: t)
            return out[k] == nil ? nil : k
        }
        // A window you corrected was misread from `since` until you said so.
        var wrongs: [String: [DateInterval]] = [:]
        for c in corrections where c.at > c.since {
            for w in c.windows { wrongs[w, default: []].append(DateInterval(start: c.since, end: c.at)) }
        }
        for (w, list) in wrongs {
            var merged: [DateInterval] = []
            for i in list.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, i.start <= last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
                } else {
                    merged.append(i)
                }
            }
            wrongs[w] = merged
        }
        func wrongSeconds(_ window: String, _ a: Date, _ e: Date) -> Double {
            (wrongs[window] ?? []).reduce(0) { $0 + max(0, min(e, $1.end).timeIntervalSince(max(a, $1.start))) }
        }
        let sortedBlocks = blocks.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
        for span in spans where span.end > from && span.start < to {
            for b in sortedBlocks where b.start < span.end && b.end > span.start {
                var a = max(span.start, b.start, from)
                let end = min(span.end, b.end, to)
                while a < end {
                    let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: a)) ?? end
                    let e = min(end, dayEnd)
                    let seconds = e.timeIntervalSince(a)
                    if let k = key(a), seconds > 0 {
                        out[k]!.readSeconds += seconds
                        if let c = span.category, !span.uncertain {
                            out[k]!.labeledSeconds += seconds
                            if c == b.label { out[k]!.rightSeconds += seconds - wrongSeconds(span.window, a, e) }
                        }
                    }
                    a = e
                }
            }
        }
        for s in autoSwitches where s.at >= from && s.at < to {
            guard let k = key(s.at) else { continue }
            out[k]!.autoSwitches += 1
            if s.undone { out[k]!.undone += 1 }
        }
        for c in corrections where c.at >= from && c.at < to {
            guard let k = key(c.at) else { continue }
            out[k]!.corrections += 1
            if c.toCourse != nil { out[k]!.courseCorrections += 1 }
        }
        return out.values.sorted { $0.day < $1.day }
    }

    /// The whole period as one day-shaped total.
    public static func total(_ days: [Day]) -> Day {
        var t = Day(day: days.first?.day ?? .distantPast)
        for d in days {
            t.readSeconds += d.readSeconds; t.labeledSeconds += d.labeledSeconds; t.rightSeconds += d.rightSeconds
            t.autoSwitches += d.autoSwitches; t.undone += d.undone
            t.corrections += d.corrections; t.courseCorrections += d.courseCorrections
        }
        return t
    }
}
