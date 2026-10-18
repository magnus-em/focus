import Foundation
import SwiftData

/// Repaints a stretch of the saved log as one category in a single save, with
/// an exact undo. Shared by the Mac's review fixes and the phone's log edits.
public enum LogEdit {
    /// The saved rows touching [start, end] before and right after an edit.
    public struct Undo: Sendable {
        let start: Date
        let end: Date
        let before: [WorkSession]
        let after: [WorkSession]
    }

    /// Rows touching [start, end] are trimmed or split around it, then it is
    /// filled with `label` (nil = Break), split at midnight; `fill: false`
    /// leaves it untracked. Refuses (nil) when the context has unsaved
    /// changes, so a failed save can't roll back someone else's work, or when
    /// the save fails.
    public static func paint(start: Date, end: Date, label: String?, fill: Bool = true, in context: ModelContext) -> Undo? {
        // Saved time can't reach past now; a row that did (10/18, Meals to
        // 5:50 AM tomorrow) is cut there instead of keeping a future tail.
        let now = Date()
        let end = min(end, now)
        guard end.timeIntervalSince(start) >= 60, !context.hasChanges else { return nil }
        do {
            let models = try rows(start, end, in: context)
            let before = models.map(\.asValue)
            for model in models {
                let a = model.startTime
                let b = min(a.addingTimeInterval(model.durationMinutes * 60), max(now, end))
                guard a < end, b > start else { continue }
                if b > end {
                    context.insert(StoredWorkSession(value: WorkSession(
                        startTime: end, durationMinutes: b.timeIntervalSince(end) / 60,
                        type: model.type, label: model.label, breakKinds: model.breakKinds)))
                }
                if a < start {
                    model.durationMinutes = start.timeIntervalSince(a) / 60
                } else {
                    context.delete(model)
                }
            }
            var cursor = start
            while fill, cursor < end {
                let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: cursor))!
                let until = min(end, midnight)
                context.insert(StoredWorkSession(value: WorkSession(
                    startTime: cursor, durationMinutes: until.timeIntervalSince(cursor) / 60,
                    type: label == nil ? .shortBreak : .work, label: label)))
                cursor = until
            }
            let after = try rows(start, end, in: context).map(\.asValue)
            try context.save()
            return Undo(start: start, end: end, before: before, after: after)
        } catch {
            context.rollback()
            return nil
        }
    }

    /// Removes one saved block, leaving a gap.
    public static func delete(id: UUID, in context: ModelContext) -> Undo? {
        guard !context.hasChanges else { return nil }
        do {
            guard let model = try context.fetch(FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.id == id })).first
            else { return nil }
            let start = model.startTime, end = start.addingTimeInterval(model.durationMinutes * 60)
            let before = try rows(start, end, in: context).map(\.asValue)
            context.delete(model)
            let after = try rows(start, end, in: context).map(\.asValue)
            try context.save()
            return Undo(start: start, end: end, before: before, after: after)
        } catch {
            context.rollback()
            return nil
        }
    }

    /// `keep` nil: merge a block saved twice. Otherwise `keep` takes the
    /// stretch both cover; with `removing`, that block goes entirely. Only the
    /// two blocks change, and only if they still look the way the user saw them.
    public static func fixOverlap(_ o: SessionOverlap, keep: UUID?, removing: WorkSession? = nil,
                                  in context: ModelContext) -> Undo? {
        guard !context.hasChanges else { return nil }
        let edits = removing.map(TimeIntegrity.remove)
            ?? keep.map { TimeIntegrity.resolve(o, keep: $0) } ?? TimeIntegrity.merge(o)
        let span = o.union
        func model(_ id: UUID) throws -> StoredWorkSession? {
            try context.fetch(FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.id == id })).first
        }
        do {
            let current = try [o.first.id, o.second.id].compactMap { try model($0)?.asValue }
            guard same(current, [o.first, o.second]) else { return nil }
            let before = try rows(span.start, span.end, in: context).map(\.asValue)
            for edit in edits {
                switch edit {
                case .setDuration(let id, let minutes):
                    guard let m = try model(id) else { throw CocoaError(.validationMissingMandatoryProperty) }
                    m.durationMinutes = minutes
                case .delete(let id):
                    guard let m = try model(id) else { throw CocoaError(.validationMissingMandatoryProperty) }
                    context.delete(m)
                case .insert(let s):
                    context.insert(StoredWorkSession(value: s))
                }
            }
            let after = try rows(span.start, span.end, in: context).map(\.asValue)
            try context.save()
            return Undo(start: span.start, end: span.end, before: before, after: after)
        } catch {
            context.rollback()
            return nil
        }
    }

    /// Restores the rows as they were, but only if nothing touched them since
    /// (another edit, a sync); otherwise refuses.
    public static func undo(_ undo: Undo, in context: ModelContext) -> Bool {
        guard !context.hasChanges else { return false }
        do {
            let models = try rows(undo.start, undo.end, in: context)
            guard same(models.map(\.asValue), undo.after) else { return false }
            let beforeIDs = Set(undo.before.map(\.id))
            for m in models where !beforeIDs.contains(m.id) { context.delete(m) }
            for old in undo.before {
                if let m = models.first(where: { $0.id == old.id }) {
                    m.startTime = old.startTime
                    m.durationMinutes = old.durationMinutes
                    m.typeRaw = old.type.rawValue
                    m.label = old.label
                    m.breakKinds = old.breakKinds
                } else {
                    context.insert(StoredWorkSession(value: old))
                }
            }
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private static func rows(_ start: Date, _ end: Date, in context: ModelContext) throws -> [StoredWorkSession] {
        let descriptor = FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.startTime <= end })
        return try context.fetch(descriptor).filter {
            !$0.isDeleted && $0.startTime.addingTimeInterval($0.durationMinutes * 60) >= start
        }
    }

    private static func same(_ a: [WorkSession], _ b: [WorkSession]) -> Bool {
        guard a.count == b.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) })
        return a.allSatisfy { x in
            guard let y = byID[x.id] else { return false }
            return abs(x.startTime.timeIntervalSince(y.startTime)) < 0.5
                && abs(x.durationMinutes - y.durationMinutes) < 0.01
                && x.type == y.type && x.label == y.label && x.breakKinds == y.breakKinds
        }
    }
}
