import Foundation
import FocusCore
import SwiftData
import SwiftUI

class SessionStore: ObservableObject {
    @Published var sessions: [WorkSession] = []
    /// Saved blocks covering the same time in the last week, newest first.
    /// Resolved automatically a few seconds after they appear (`TimeIntegrity.autoKeep`).
    @Published private(set) var overlaps: [SessionOverlap] = []
    /// Why the last save failed, until one succeeds (10/14: a full disk
    /// failed saves silently).
    @Published private(set) var saveError: String?
    /// Free space on the startup disk when it's under 5 GB.
    @Published private(set) var lowDiskGB: Double?

    private let context: ModelContext
    private var dayChangedObserver: NSObjectProtocol?
    private var remoteObserver: NSObjectProtocol?
    private var remoteRefresh: DispatchWorkItem?
    private var diskCheckedAt = Date.distantPast
    private var autoResolve: DispatchWorkItem?

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        refresh()

        // Rows other devices save arrive through the CloudKit mirror without
        // a local save, so nothing refreshed for them (their overlaps
        // included) until this Mac saved something itself.
        remoteObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.remoteRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self.remoteRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }

        // Force SwiftUI views observing "today" computeds (todayWorkMinutes,
        // todayWorkSessions, todayBreakMinutes, todaySessionCount, etc.) to
        // re-render when the calendar day rolls over at midnight. The
        // underlying filter uses `Calendar.isDateInToday(...)` — correct on
        // every call, but a menu-bar app that stays open across midnight
        // never gets a publisher event to trigger SwiftUI's body re-eval.
        // NSCalendarDayChanged is broadcast by the system at midnight and
        // any time the user changes time/timezone.
        dayChangedObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let o = dayChangedObserver { NotificationCenter.default.removeObserver(o) }
        if let o = remoteObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Belt-and-suspenders: invoked from the popover's `.onAppear` so that
    /// even if the day-change notification was missed (app was asleep at
    /// midnight, or system never fired it for some reason), the UI
    /// re-evaluates "today" filters as soon as the user looks at it.
    func touchForToday() {
        objectWillChange.send()
    }

    private func refresh() {
        var descriptor = FetchDescriptor<StoredWorkSession>(
            sortBy: [SortDescriptor(\.startTime)]
        )
        descriptor.includePendingChanges = true
        let stored = (try? context.fetch(descriptor)) ?? []
        sessions = stored.map { $0.asValue }
        let now = Date()
        overlaps = TimeIntegrity.overlaps(in: sessions, from: now.addingTimeInterval(-7 * 86400), to: now)
        if !overlaps.isEmpty, autoResolve == nil {
            // Waits for a burst of CloudKit imports to settle, so both rows of a
            // block another device is still saving are there before deciding.
            let work = DispatchWorkItem { [weak self] in
                self?.autoResolve = nil
                self?.resolveOverlaps()
            }
            autoResolve = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        }
        if now.timeIntervalSince(diskCheckedAt) > 60 {
            diskCheckedAt = now
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            lowDiskGB = free.map { Double($0) / 1e9 }.flatMap { $0 < 5 ? $0 : nil }
        }
    }

    func addSession(_ session: WorkSession) {
        // De-dup: when a timer finishes on this device AND on a peer mirror
        // (e.g. iPad-Mac live sync), both insertSession paths fire. Guard
        // by looking up any existing session within ±3s of this startTime
        // with matching type + label. Reason: SwiftData/CloudKit doesn't
        // support unique constraints, so this is the only race-safe place.
        let start = session.startTime
        let lower = start.addingTimeInterval(-3)
        let upper = start.addingTimeInterval(3)
        let typeRaw = session.type.rawValue
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { existing in
                existing.startTime >= lower &&
                existing.startTime <= upper &&
                existing.typeRaw == typeRaw
            }
        )
        if let dupe = (try? context.fetch(descriptor))?.first(where: { $0.label == session.label }) {
            // Same block saved twice (peer + here, or a re-adopted state):
            // keep the longer one rather than whichever landed first.
            if session.durationMinutes > dupe.durationMinutes {
                dupe.durationMinutes = session.durationMinutes
                save()
                refresh()
            }
            return
        }
        context.insert(StoredWorkSession(value: session))
        save()
        refresh()
    }

    /// Every save goes through here, so a failure shows in the popover
    /// instead of vanishing. Pending changes stay for the next try.
    private func save() {
        do {
            try context.save()
            if saveError != nil { saveError = nil }
        } catch {
            saveError = error.localizedDescription
            SyncLog.event("sessionSaveFailed", ["error": error.localizedDescription])
        }
    }

    private func resolveOverlaps() {
        for _ in 0..<200 {
            let now = Date()
            guard let o = TimeIntegrity.overlaps(in: sessions, from: now.addingTimeInterval(-7 * 86400), to: now).first
            else { break }
            let keep = TimeIntegrity.autoKeep(o)
            guard LogEdit.fixOverlap(o, keep: keep, in: context) != nil else { break }
            SyncLog.event("overlapAutoResolved", ["first": o.first.id.uuidString, "second": o.second.id.uuidString,
                                                  "kept": keep?.uuidString ?? "merged"])
            let descriptor = FetchDescriptor<StoredWorkSession>(sortBy: [SortDescriptor(\.startTime)])
            sessions = ((try? context.fetch(descriptor)) ?? []).map { $0.asValue }
        }
        refresh()
    }

    private func model(_ id: UUID) throws -> StoredWorkSession? {
        var d = FetchDescriptor<StoredWorkSession>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    /// Ends one saved block at `end` (after its start, before its current end).
    func setEnd(id: UUID, end: Date) -> Bool {
        guard let m = try? model(id), end > m.startTime,
              end < m.startTime.addingTimeInterval(m.durationMinutes * 60) else { return false }
        m.durationMinutes = end.timeIntervalSince(m.startTime) / 60
        save()
        refresh()
        return saveError == nil
    }

    func updateLabel(id: UUID, label: String?) {
        let target = id
        let predicate = #Predicate<StoredWorkSession> { $0.id == target }
        var descriptor = FetchDescriptor<StoredWorkSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let model = try? context.fetch(descriptor).first {
            model.label = label
            save()
            refresh()
        }
    }

    func delete(id: UUID) {
        let target = id
        try? context.delete(model: StoredWorkSession.self, where: #Predicate { $0.id == target })
        save()
        refresh()
    }

    func updateBreakKinds(id: UUID, kinds: [BreakKind]) {
        let target = id
        let predicate = #Predicate<StoredWorkSession> { $0.id == target }
        var descriptor = FetchDescriptor<StoredWorkSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let model = try? context.fetch(descriptor).first {
            model.breakKinds = kinds.isEmpty ? nil : kinds
            save()
            refresh()
        }
    }

    typealias ReviewUndo = LogEdit.Undo

    func paintForReview(start: Date, end: Date, label: String?) -> ReviewUndo? {
        let undo = LogEdit.paint(start: start, end: end, label: label, in: context)
        refresh()
        return undo
    }

    func undoReview(_ undo: ReviewUndo) -> Bool {
        let done = LogEdit.undo(undo, in: context)
        refresh()
        return done
    }

    /// Relabel [start, end) as `label` (nil = break): saved sessions are
    /// trimmed or split around it, then the span is filled.
    func paint(start: Date, end: Date, label: String?) {
        guard end.timeIntervalSince(start) >= 60 else { return }
        let earliest = start.addingTimeInterval(-2 * 86400)
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { $0.startTime < end && $0.startTime > earliest }
        )
        for m in (try? context.fetch(descriptor)) ?? [] {
            let s = m.startTime, e = s.addingTimeInterval(m.durationMinutes * 60)
            guard e > start else { continue }
            if e.timeIntervalSince(end) >= 60 {
                let tail = WorkSession(startTime: end, durationMinutes: e.timeIntervalSince(end) / 60,
                                       type: m.type, label: m.label, breakKinds: m.breakKinds)
                context.insert(StoredWorkSession(value: tail))
            }
            if start.timeIntervalSince(s) >= 60 {
                m.durationMinutes = start.timeIntervalSince(s) / 60
            } else {
                context.delete(m)
            }
        }
        save()
        refresh()
        fill(start: start, end: end, label: label)
    }

    func clearAllData() {
        try? context.delete(model: StoredWorkSession.self)
        save()
        refresh()
    }

    // MARK: - Today

    var todayWorkSessions: [WorkSession] {
        let calendar = Calendar.current
        return sessions.filter {
            $0.isFocus && calendar.isDateInToday($0.startTime)
        }
    }

    var todayWorkMinutes: Double {
        todayWorkSessions.reduce(0) { $0 + $1.durationMinutes }
    }

    var todaySessionCount: Int {
        todayWorkSessions.count
    }

    var todayBreakMinutes: Double {
        let calendar = Calendar.current
        return sessions
            .filter { $0.type.isBreak && calendar.isDateInToday($0.startTime) }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    // MARK: - Streaks

    var currentStreak: Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        // If today has no sessions yet, start from yesterday
        if !hasSessions(on: checkDate) {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }

        while hasSessions(on: checkDate) {
            streak += 1
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }

        return streak
    }

    private func hasSessions(on date: Date) -> Bool {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)!
        return sessions.contains {
            $0.isFocus && $0.startTime >= date && $0.startTime < dayEnd
        }
    }

    // MARK: - Lifetime

    var totalWorkHours: Double {
        sessions.filter { $0.isFocus }.reduce(0) { $0 + $1.durationMinutes } / 60.0
    }

    var totalWorkSessions: Int {
        sessions.filter { $0.isFocus }.count
    }

    var bestStreak: Int {
        let calendar = Calendar.current
        let activeDays = Set(sessions
            .filter { $0.isFocus }
            .map { calendar.startOfDay(for: $0.startTime) }
        ).sorted()

        guard !activeDays.isEmpty else { return 0 }

        var best = 1
        var current = 1
        for i in 1..<activeDays.count {
            let diff = calendar.dateComponents([.day], from: activeDays[i-1], to: activeDays[i]).day ?? 0
            if diff == 1 {
                current += 1
                if current > best { best = current }
            } else if diff > 1 {
                current = 1
            }
        }
        return max(best, currentStreak)
    }

    var bestDayMinutes: Double {
        let calendar = Calendar.current
        var dailyTotals: [Date: Double] = [:]
        for session in sessions where session.isFocus {
            let day = calendar.startOfDay(for: session.startTime)
            dailyTotals[day, default: 0] += session.durationMinutes
        }
        return dailyTotals.values.max() ?? 0
    }

    // MARK: - Charts

    /// Returns (date, minutes) for the last `weeks` calendar weeks, starting on Sunday.
    /// minutes == -1 means a future date (render as empty).
    func heatmapData(weeks: Int) -> [(date: Date, minutes: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1=Sun … 7=Sat
        let thisSunday = calendar.date(byAdding: .day, value: -(weekday - 1), to: today)!
        let startDate = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisSunday)!

        return (0..<(weeks * 7)).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: startDate)!
            guard date <= today else { return (date: date, minutes: -1) }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)!
            let mins = sessions.filter {
                $0.isFocus && $0.startTime >= date && $0.startTime < dayEnd
            }.reduce(0.0) { $0 + $1.durationMinutes }
            return (date: date, minutes: mins)
        }
    }

    func dailySummaries(last days: Int) -> [DailySummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return (0..<days).map { daysAgo in
            let date = calendar.date(byAdding: .day, value: -(days - 1 - daysAgo), to: today)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)!

            let daySessions = sessions.filter {
                $0.isFocus && $0.startTime >= date && $0.startTime < dayEnd
            }

            let totalMinutes = daySessions.reduce(0.0) { $0 + $1.durationMinutes }

            return DailySummary(
                id: "day-\(daysAgo)",
                date: date,
                totalWorkMinutes: totalMinutes,
                sessionCount: daySessions.count
            )
        }
    }

    /// Total work minutes grouped by label, sorted descending. Includes all historical labels.
    func minutesByTag(includeLife: Bool = false) -> [(tag: String, minutes: Double)] {
        var dict: [String: Double] = [:]
        for session in sessions where includeLife ? session.type == .work : session.isFocus {
            guard let label = session.label, !label.isEmpty else { continue }
            dict[label, default: 0] += session.durationMinutes
        }
        return dict.map { (tag: $0.key, minutes: $0.value) }.sorted { $0.minutes > $1.minutes }
    }

    func weeklyAverage() -> Double {
        let summaries = dailySummaries(last: 7)
        let activeDays = summaries.filter { $0.totalWorkMinutes > 0 }.count
        guard activeDays > 0 else { return 0 }
        let total = summaries.reduce(0) { $0 + $1.totalWorkMinutes }
        return total / Double(activeDays)
    }

    // MARK: - Ranged queries

    func workMinutes(since start: Date, until end: Date? = nil) -> Double {
        let end = end ?? Date()
        return sessions.filter {
            $0.isFocus && $0.startTime >= start && $0.startTime < end
        }.reduce(0.0) { $0 + $1.durationMinutes }
    }

    func minutesByTag(since start: Date, until end: Date? = nil) -> [(tag: String, minutes: Double)] {
        let end = end ?? Date()
        var dict: [String: Double] = [:]
        for s in sessions where s.isFocus && s.startTime >= start && s.startTime < end {
            guard let label = s.label, !label.isEmpty else { continue }
            dict[label, default: 0] += s.durationMinutes
        }
        return dict.map { (tag: $0.key, minutes: $0.value) }.sorted { $0.minutes > $1.minutes }
    }

    /// Last 7 days (rolling, including today).
    var last7DaysMinutes: Double {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        return workMinutes(since: start)
    }

    /// The 7-day window before `last7Days` (days -13 through -7).
    var prior7DaysMinutes: Double {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: Date()))!
        let end = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        return workMinutes(since: start, until: end)
    }

    /// Fraction of the last `days` calendar days that had any work sessions.
    func consistencyScore(days: Int) -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var count = 0
        for i in 0..<days {
            let date = calendar.date(byAdding: .day, value: -i, to: today)!
            if hasSessions(on: date) { count += 1 }
        }
        return Double(count) / Double(days)
    }

    /// Most minutes logged in any rolling 7-day window.
    var bestWeekMinutes: Double {
        let calendar = Calendar.current
        var dailyTotals: [Date: Double] = [:]
        for session in sessions where session.isFocus {
            let day = calendar.startOfDay(for: session.startTime)
            dailyTotals[day, default: 0] += session.durationMinutes
        }
        guard !dailyTotals.isEmpty else { return 0 }
        var best = 0.0
        for startDay in dailyTotals.keys {
            var weekTotal = 0.0
            for offset in 0..<7 {
                let day = calendar.date(byAdding: .day, value: offset, to: startDay)!
                weekTotal += dailyTotals[day] ?? 0
            }
            best = max(best, weekTotal)
        }
        return best
    }

    /// Average minutes/session over the last `n` work sessions.
    func averageSessionMinutes(last n: Int = 20) -> Double {
        let recent = sessions.filter { $0.isFocus }.suffix(n)
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0.0) { $0 + $1.durationMinutes } / Double(recent.count)
    }
}
