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

    /// What's running, nil for Break; only meaningful while active.
    private var running: String? { engine.isOnBreak ? nil : engine.currentLabel }

    /// [start, end] becomes `label` (nil = Break). Reaching into the running
    /// block moves it: up to now, it becomes `label` from `start`; short of
    /// now, it starts at `end` instead ("Reading until 11:00" while Chores
    /// runs from 10:52). Inside it, that stretch is cut out of it.
    func set(_ start: Date, _ end: Date, to label: String?) -> Outcome {
        let now = Date()
        let end = min(end, now)
        guard end.timeIntervalSince(start) >= 60 else { return Outcome() }
        guard engine.isActive, let r = engine.sessionStartTime, end > r.addingTimeInterval(30) else {
            return paint(start, end, label)
        }
        if end >= now.addingTimeInterval(-90) {
            if start <= r.addingTimeInterval(60) {
                return setRunning(from: start, to: label)
            }
            if let label { engine.switchTo(label, at: start) } else { engine.startBreak(minutes: 0, at: start) }
            return Outcome(movedTimer: true)
        }
        if start >= r {
            guard label != running else { return Outcome() }
            engine.carveOut(from: start, to: end, as: label)
            return Outcome(movedTimer: true)
        }
        engine.moveStart(to: end)
        var out = paint(start, end, label)
        out.movedTimer = true
        return out
    }

    /// The running block is `label` (nil = Break) from `start`, earlier or
    /// later than it began. Earlier takes over what's logged in between;
    /// later leaves the time before it untracked.
    func setRunning(from start: Date, to label: String?) -> Outcome {
        guard engine.isActive, let r = engine.sessionStartTime else { return Outcome(problem: "Nothing is running.") }
        if abs(start.timeIntervalSince(r)) >= 30 { engine.moveStart(to: start) }
        if label != running {
            if let label { engine.relabel(label) } else { engine.startBreak(minutes: 0, at: engine.sessionStartTime ?? start) }
        }
        return Outcome(movedTimer: true)
    }

    /// `label` from `at` on, and running. Saved time after `at` becomes
    /// `label` too, so nothing is counted twice. The same category as what's
    /// running just moves its start, either way.
    func start(_ label: String, at: Date) -> Outcome {
        guard engine.isActive else {
            engine.switchTo(label, at: at)
            return Outcome(movedTimer: true)
        }
        if label == running { return setRunning(from: at, to: label) }
        return set(at, Date(), to: label)
    }

    private func paint(_ start: Date, _ end: Date, _ label: String?) -> Outcome {
        try? context.save()
        guard let undo = LogEdit.paint(start: start, end: end, label: label, in: context) else {
            return Outcome(problem: "Couldn't save that. Try again.")
        }
        return Outcome(undos: [undo])
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
