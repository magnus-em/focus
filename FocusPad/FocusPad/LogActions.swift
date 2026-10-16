import Foundation
import SwiftData
import FocusCore

/// Every change the phone makes to the log goes through here. Saved time is
/// repainted with `LogEdit` (undoable); time inside the running block moves
/// the timer instead, which Undo can't take back.
@MainActor
struct LogActions {
    let engine: FocusTimerEngine
    let context: ModelContext

    struct Outcome {
        var undos: [LogEdit.Undo] = []
        var movedTimer = false
        var problem: String?
    }

    /// [start, end] becomes `label` (nil = Break).
    func set(_ start: Date, _ end: Date, to label: String?) -> Outcome {
        var out = Outcome()
        let now = Date()
        let end = min(end, now)
        let runStart = engine.isActive ? engine.sessionStartTime : nil
        let savedEnd = min(end, runStart ?? end)
        if savedEnd.timeIntervalSince(start) >= 60 {
            try? context.save()
            guard let undo = LogEdit.paint(start: start, end: savedEnd, label: label, in: context) else {
                out.problem = "Couldn't save that. Try again."
                return out
            }
            out.undos.append(undo)
        }
        guard let runStart, end.timeIntervalSince(max(start, runStart)) >= 60 else { return out }
        let from = max(start, runStart)
        guard end >= now.addingTimeInterval(-90) else {
            out.problem = "Part of that is inside what's running now. Stop it first, or fix it on the Mac."
            return out
        }
        if let label {
            engine.switchTo(label, at: from)
        } else if now.timeIntervalSince(from) < 120 {
            engine.startManualBreak(minutes: 0)
        } else {
            out.problem = "A break can only start now from the phone."
            return out
        }
        out.movedTimer = true
        return out
    }

    /// `label` from `at` on, and running. Saved time after `at` becomes
    /// `label` too, so nothing is counted twice.
    func start(_ label: String, at: Date) -> Outcome {
        let runStart = engine.isActive ? engine.sessionStartTime : nil
        if let runStart, at >= runStart {
            engine.switchTo(label, at: at)
            return Outcome(movedTimer: true)
        }
        var out = set(at, runStart ?? Date(), to: label)
        guard out.problem == nil else { return out }
        if let runStart { engine.switchTo(label, at: runStart) } else { engine.switchTo(label) }
        out.movedTimer = true
        return out
    }

    func fixOverlap(_ o: SessionOverlap, keep: UUID?) -> Outcome {
        try? context.save()
        guard let undo = LogEdit.fixOverlap(o, keep: keep, in: context) else {
            return Outcome(problem: "The log changed. Look again.")
        }
        return Outcome(undos: [undo])
    }

    /// Leaves [start, end] untracked. Not for the running block.
    func clear(_ start: Date, _ end: Date) -> Outcome {
        try? context.save()
        guard let undo = LogEdit.paint(start: start, end: end, label: nil, fill: false, in: context) else {
            return Outcome(problem: "Couldn't change that. Try again.")
        }
        return Outcome(undos: [undo])
    }

    func undo(_ undos: [LogEdit.Undo]) -> Bool {
        try? context.save()
        for undo in undos.reversed() where !LogEdit.undo(undo, in: context) { return false }
        return true
    }
}

/// One block of the day as the phone shows it: saved rows plus the running one.
struct LogRow: Identifiable, Equatable {
    var id: UUID
    var start: Date
    var end: Date
    /// nil = Break.
    var label: String?
    var running: Bool

    var name: String { label ?? "Break" }
    var minutes: Double { end.timeIntervalSince(start) / 60 }

    /// The day's rows, oldest first, clipped to the day; same-label neighbours
    /// that touch are shown as one.
    @MainActor
    static func rows(_ sessions: [StoredWorkSession], engine: FocusTimerEngine, day: Date, now: Date = Date()) -> [LogRow] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = min(cal.date(byAdding: .day, value: 1, to: dayStart)!, now)
        var rows = sessions.compactMap { s -> LogRow? in
            let a = max(s.startTime, dayStart)
            let b = min(s.startTime.addingTimeInterval(s.durationMinutes * 60), dayEnd)
            guard b.timeIntervalSince(a) >= 30 else { return nil }
            return LogRow(id: s.id, start: a, end: b, label: s.type == .work ? (s.label ?? "Focus") : nil, running: false)
        }
        if engine.isActive, let start = engine.sessionStartTime, start < dayEnd, now > dayStart {
            rows.append(LogRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, start: max(start, dayStart),
                               end: dayEnd, label: engine.isOnBreak ? nil : engine.currentLabel, running: true))
        }
        rows.sort { $0.start < $1.start }
        var merged: [LogRow] = []
        for row in rows {
            if var last = merged.last, last.label == row.label, abs(row.start.timeIntervalSince(last.end)) < 60, !last.running {
                last.end = max(last.end, row.end)
                last.running = row.running
                if row.running { last.id = row.id }
                merged[merged.count - 1] = last
            } else {
                merged.append(row)
            }
        }
        return merged
    }

    /// Untracked stretches of at least `minimum` minutes between `from` and the last row (or now).
    static func gaps(_ rows: [LogRow], day: Date, now: Date = Date(), minimum: Double = 10) -> [(start: Date, end: Date)] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = min(cal.date(byAdding: .day, value: 1, to: dayStart)!, now)
        var out: [(Date, Date)] = []
        var cursor = dayStart
        for row in rows.sorted(by: { $0.start < $1.start }) {
            if row.start.timeIntervalSince(cursor) >= minimum * 60 { out.append((cursor, row.start)) }
            cursor = max(cursor, row.end)
        }
        if dayEnd.timeIntervalSince(cursor) >= minimum * 60 { out.append((cursor, dayEnd)) }
        return out
    }
}
