import Foundation

/// Two saved blocks covering the same stretch: that time counts twice.
public struct SessionOverlap: Sendable {
    /// The block that started first.
    public let first: WorkSession
    public let second: WorkSession
    /// The stretch both cover.
    public let start: Date
    public let end: Date

    /// Same category (or both breaks): one block saved twice, so merging is
    /// the obvious fix. Otherwise only the user knows which one it was.
    public var sameLabel: Bool {
        first.type.isBreak == second.type.isBreak && (first.type.isBreak || first.label == second.label)
    }

    /// From the first block's start to the later of the two ends.
    public var union: (start: Date, end: Date) {
        (first.startTime, max(TimeIntegrity.end(of: first), TimeIntegrity.end(of: second)))
    }

    /// Stable across refreshes, for "don't ask again".
    public var key: String { "\(first.id.uuidString)|\(second.id.uuidString)" }
}

/// One change to a saved block. Fixes touch only the two blocks shown.
public enum OverlapEdit: Sendable {
    case setDuration(UUID, minutes: Double)
    case delete(UUID)
    case insert(WorkSession)
}

public enum TimeIntegrity {
    /// Same category saved twice: the earlier block grows to cover both and
    /// the other goes. Any third block in that span is left alone (its own
    /// overlap shows next).
    public static func merge(_ o: SessionOverlap) -> [OverlapEdit] {
        [.setDuration(o.first.id, minutes: o.union.end.timeIntervalSince(o.first.startTime) / 60),
         .delete(o.second.id)]
    }

    /// A block that overlaps several others is usually one a device saved
    /// after missing the switches (10/14: the iPhone's Class 12:42 → 5:54 over
    /// ten blocks). Removing it is one fix instead of ten.
    public static func remove(_ block: WorkSession) -> [OverlapEdit] { [.delete(block.id)] }

    /// How many overlaps in `overlaps` involve `block`.
    public static func overlapCount(_ block: WorkSession, in overlaps: [SessionOverlap]) -> Int {
        overlaps.filter { $0.first.id == block.id || $0.second.id == block.id }.count
    }

    /// `keep` takes the stretch both cover; only the other block changes:
    /// it's cut around that stretch, keeping whatever lies outside it.
    public static func resolve(_ o: SessionOverlap, keep: UUID) -> [OverlapEdit] {
        let loser = keep == o.first.id ? o.second : o.first
        let a = loser.startTime, b = end(of: loser)
        var edits: [OverlapEdit] = a < o.start
            ? [.setDuration(loser.id, minutes: o.start.timeIntervalSince(a) / 60)]
            : [.delete(loser.id)]
        if b > o.end {
            edits.append(.insert(WorkSession(startTime: o.end, durationMinutes: b.timeIntervalSince(o.end) / 60,
                                             type: loser.type, label: loser.label, breakKinds: loser.breakKinds)))
        }
        return edits
    }

    /// Which block keeps the shared stretch, decided without asking (user,
    /// 10/16: "just make it automatically decide"). nil = same category, merge.
    /// Otherwise the block that started later: it's the switch made last, and
    /// a block covering others is almost always a device that missed those
    /// switches (10/14: Class 12:42 → 5:22 over nine blocks). Same start: the shorter.
    public static func autoKeep(_ o: SessionOverlap) -> UUID? {
        if o.sameLabel { return nil }
        if o.second.startTime > o.first.startTime { return o.second.id }
        return o.first.durationMinutes <= o.second.durationMinutes ? o.first.id : o.second.id
    }

    public static func end(of s: WorkSession) -> Date {
        s.startTime.addingTimeInterval(s.durationMinutes * 60)
    }

    /// Overlaps of at least `minSeconds` between saved blocks that touch
    /// [from, to), newest first. Edges a few seconds apart are rounding, not
    /// double counting.
    public static func overlaps(in sessions: [WorkSession], from: Date, to: Date,
                                minSeconds: TimeInterval = 60) -> [SessionOverlap] {
        let rows = sessions
            .filter { $0.durationMinutes > 0 && end(of: $0) > from && $0.startTime < to }
            .sorted { $0.startTime < $1.startTime }
        var found: [SessionOverlap] = []
        for i in rows.indices {
            let a = rows[i]
            let aEnd = end(of: a)
            var j = i + 1
            while j < rows.count, rows[j].startTime < aEnd {
                let b = rows[j]
                let overlapEnd = min(aEnd, end(of: b))
                if overlapEnd.timeIntervalSince(b.startTime) >= minSeconds {
                    found.append(SessionOverlap(first: a, second: b, start: b.startTime, end: overlapEnd))
                }
                j += 1
            }
        }
        return found.sorted { $0.start > $1.start }
    }
}
