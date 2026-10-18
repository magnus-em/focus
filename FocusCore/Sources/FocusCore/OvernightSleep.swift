import Foundation

/// A block left running through the night (Recruiting from 11 PM to 10 AM)
/// becomes Sleep where nobody touched any device. Pure rule; the Mac applies
/// it with Undo.
public enum OvernightSleep {
    public struct Block: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var label: String?
        public var running: Bool
        public init(start: Date, end: Date, label: String?, running: Bool = false) {
            self.start = start; self.end = end; self.label = label; self.running = running
        }
    }

    public struct Fix: Equatable, Sendable {
        public var start: Date
        public var end: Date
        /// What the block was (nil = Break).
        public var label: String?
        public var running: Bool
        /// The night it belongs to, so an undone night isn't redone.
        public var night: DateInterval
        public var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    public static let minNight: TimeInterval = 3 * 3600
    /// Longer than this is a trip, not a night: left for the away card.
    public static let maxNight: TimeInterval = 16 * 3600
    /// Phone or iPad use shorter than this (checking the time) doesn't wake you.
    public static let minActivity: TimeInterval = 10 * 60
    static let coreHours = 1..<6
    static let minCoreOverlap: TimeInterval = 3600
    static let wakeAfterHour = 5
    static let minFix: TimeInterval = 30 * 60
    /// A block picked this soon after you left was picked as you left.
    static let leaveSlack: TimeInterval = 5 * 60

    /// Away stretches that look like a night's sleep: no device used for 3h+,
    /// covering an hour or more of 1–6 AM and lasting past 5 AM. `wakes` split
    /// a stretch like device use does.
    public static func nights(away: [DateInterval], activity: [DateInterval], wakes: [Date] = [],
                              calendar: Calendar = .current) -> [DateInterval] {
        let awake = merged(activity, within: 5 * 60).filter { $0.duration >= minActivity }
            + wakes.map { DateInterval(start: $0, duration: 0) }
        return merged(away, within: 60).flatMap { subtract(awake, from: $0) }.filter { piece in
            guard piece.duration >= minNight, piece.duration <= maxNight else { return false }
            var day = calendar.startOfDay(for: piece.start.addingTimeInterval(-86400))
            while day < piece.end {
                let core = DateInterval(start: calendar.date(byAdding: .hour, value: coreHours.lowerBound, to: day)!,
                                        end: calendar.date(byAdding: .hour, value: coreHours.upperBound, to: day)!)
                let wake = calendar.date(byAdding: .hour, value: wakeAfterHour, to: day)!
                if let o = piece.intersection(with: core), o.duration >= minCoreOverlap, piece.end >= wake { return true }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return false
        }
    }

    /// The parts of non-Sleep blocks, already running when you left, that fall
    /// inside a night. Picking a category during the night (Meals on the phone
    /// at 10 while the Mac still counts you away, Sleep at midnight) means you
    /// were up: that block is never touched and the night is split there.
    /// Never past `now`.
    public static func fixes(away: [DateInterval], activity: [DateInterval], blocks: [Block],
                             now: Date, calendar: Calendar = .current) -> [Fix] {
        let blocks = blocks.sorted { $0.start < $1.start }
        // A row split at midnight, or saved and carried on, is the same block.
        var origin: [Date] = []
        for (i, b) in blocks.enumerated() {
            let prev = blocks[..<i].lastIndex { $0.label == b.label && abs($0.end.timeIntervalSince(b.start)) < 60 }
            origin.append(prev.map { origin[$0] } ?? b.start)
        }
        // Any category picked mid-night, Sleep included, was picked by someone awake.
        let picks = blocks.indices.filter { origin[$0] == blocks[$0].start }.map { blocks[$0].start }
        let wakes = picks.filter { p in away.contains { p > $0.start.addingTimeInterval(leaveSlack) && p < $0.end } }
        var out: [Fix] = []
        for night in nights(away: away, activity: activity, wakes: wakes, calendar: calendar) {
            var found: [Fix] = []
            for (i, b) in blocks.enumerated() where b.label != "Sleep"
                && origin[i] <= night.start.addingTimeInterval(leaveSlack) && !wakes.contains(origin[i]) {
                let a = max(night.start, b.start), e = min(night.end, b.end, now)
                guard e.timeIntervalSince(a) >= 60 else { continue }
                found.append(Fix(start: a, end: e, label: b.label, running: b.running, night: night))
            }
            if found.reduce(0, { $0 + $1.end.timeIntervalSince($1.start) }) >= minFix { out += found }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func merged(_ list: [DateInterval], within gap: TimeInterval) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in list.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, i.start.timeIntervalSince(last.end) < gap {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
            } else {
                out.append(i)
            }
        }
        return out
    }

    static func subtract(_ cuts: [DateInterval], from base: DateInterval) -> [DateInterval] {
        var pieces = [base]
        for c in cuts {
            pieces = pieces.flatMap { p -> [DateInterval] in
                guard c.start < p.end, c.end > p.start else { return [p] }
                var parts: [DateInterval] = []
                if c.start > p.start { parts.append(DateInterval(start: p.start, end: c.start)) }
                if c.end < p.end { parts.append(DateInterval(start: c.end, end: p.end)) }
                return parts
            }
        }
        return pieces
    }
}
