import Foundation
import FocusCore
import SwiftData

enum HealthTracker: String, CaseIterable, Identifiable {
    case fap, adderall

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fap: return "Jerk"
        case .adderall: return "Adderall"
        }
    }

    var kinds: [HealthKind] { HealthKind.allCases.filter { $0.tracker == self } }

    /// Fap counts occurrences; Adderall sums milligrams.
    var unit: String { self == .adderall ? "mg" : "" }
}

enum HealthKind: String, CaseIterable, Identifiable {
    case fap
    case adderallIR10, adderallIR20, adderallXR20

    var id: String { rawValue }

    var tracker: HealthTracker {
        switch self {
        case .fap: return .fap
        case .adderallIR10, .adderallIR20, .adderallXR20: return .adderall
        }
    }

    var displayName: String {
        switch self {
        case .fap: return "Jerk"
        case .adderallIR10: return "IR 10 mg"
        case .adderallIR20: return "IR 20 mg"
        case .adderallXR20: return "XR 20 mg"
        }
    }

    var amount: Int {
        switch self {
        case .fap: return 1
        case .adderallIR10: return 10
        case .adderallIR20, .adderallXR20: return 20
        }
    }
}

struct HealthEvent: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: HealthKind
}

struct HealthWeek: Identifiable {
    let start: Date
    let total: Int
    let focusHours: Double
    var id: Date { start }
}

class HealthStore: ObservableObject {
    @Published private(set) var events: [HealthEvent] = []
    @Published private(set) var saveError: String?

    private let context: ModelContext

    static let calendar: Calendar = {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }()

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        refresh()
    }

    func refresh() {
        var descriptor = FetchDescriptor<StoredHealthEvent>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.includePendingChanges = true
        let stored = (try? context.fetch(descriptor)) ?? []
        events = stored.compactMap { s in
            HealthKind(rawValue: s.kind).map { HealthEvent(id: s.id, date: s.date, kind: $0) }
        }
    }

    @discardableResult
    func log(_ kind: HealthKind, at date: Date = Date()) -> UUID? {
        let model = StoredHealthEvent(date: date, kind: kind.rawValue)
        context.insert(model)
        guard save() else { return nil }
        refresh()
        return model.id
    }

    func delete(id: UUID) {
        let predicate = #Predicate<StoredHealthEvent> { $0.id == id }
        do {
            try context.delete(model: StoredHealthEvent.self, where: predicate)
            if save() { refresh() }
        } catch { saveError = error.localizedDescription; context.rollback() }
    }

    @discardableResult
    func update(id: UUID, kind: HealthKind, at date: Date) -> Bool {
        let descriptor = FetchDescriptor<StoredHealthEvent>(predicate: #Predicate { $0.id == id })
        do {
            guard let model = try context.fetch(descriptor).first else { return false }
            model.kind = kind.rawValue
            model.date = date
            guard save() else { return false }
            refresh()
            return true
        } catch { saveError = error.localizedDescription; context.rollback(); return false }
    }

    private func save() -> Bool {
        do {
            try context.save()
            saveError = nil
            return true
        } catch {
            context.rollback()
            saveError = error.localizedDescription
            return false
        }
    }

    func doses(on day: Date, through now: Date = Date()) -> [HealthEvent] {
        events(.adderall).filter { Calendar.current.isDate($0.date, inSameDayAs: day) && $0.date <= now }
            .sorted { $0.date < $1.date }
    }

    func firstDoseToday(now: Date = Date()) -> HealthEvent? { doses(on: now, through: now).first }

    // MARK: - Stats

    func events(_ tracker: HealthTracker) -> [HealthEvent] {
        events.filter { $0.kind.tracker == tracker }
    }

    func weekStart(_ date: Date) -> Date {
        Self.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? Self.calendar.startOfDay(for: date)
    }

    func total(_ tracker: HealthTracker, from start: Date, to end: Date) -> Int {
        events.filter { $0.kind.tracker == tracker && $0.date >= start && $0.date < end }.map(\.kind.amount).reduce(0, +)
    }

    /// Today's most recent dose (the morning one unless there was a later one).
    func latestToday(_ tracker: HealthTracker, now: Date = Date()) -> HealthEvent? {
        events(tracker).first { Calendar.current.isDate($0.date, inSameDayAs: now) && $0.date <= now }
    }

    func daysSinceLast(_ tracker: HealthTracker) -> Int? {
        guard let last = events(tracker).first else { return nil }
        let cal = Self.calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: last.date), to: cal.startOfDay(for: Date())).day
    }

    /// Oldest first, ending with the current week.
    func weeks(_ tracker: HealthTracker, count n: Int, sessionStore: SessionStore) -> [HealthWeek] {
        let cal = Self.calendar
        let thisWeek = weekStart(Date())
        return (0..<n).reversed().compactMap { back in
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            return HealthWeek(
                start: start,
                total: total(tracker, from: start, to: end),
                focusHours: sessionStore.workMinutes(since: start, until: end) / 60
            )
        }
    }

    /// Average focus hours on days with vs without an event, over complete
    /// days since the first event. Nil until both groups have 3+ days.
    func focusOnVsOff(_ tracker: HealthTracker, sessionStore: SessionStore) -> (on: Double, onDays: Int, off: Double, offDays: Int)? {
        let cal = Self.calendar
        guard let first = events(tracker).last?.date else { return nil }
        let eventDays = Set(events(tracker).map { cal.startOfDay(for: $0.date) })
        let today = cal.startOfDay(for: Date())
        var on: [Double] = [], off: [Double] = []
        var day = cal.startOfDay(for: first)
        while day < today, let next = cal.date(byAdding: .day, value: 1, to: day) {
            let h = sessionStore.workMinutes(since: day, until: next) / 60
            if eventDays.contains(day) { on.append(h) } else { off.append(h) }
            day = next
        }
        guard on.count >= 3, off.count >= 3 else { return nil }
        let avg: ([Double]) -> Double = { $0.reduce(0, +) / Double($0.count) }
        return (avg(on), on.count, avg(off), off.count)
    }

    /// Longest run of whole days with no event, counting the open run up to today.
    func longestGapDays(_ tracker: HealthTracker) -> Int {
        let cal = Self.calendar
        let days = Set(events(tracker).map { cal.startOfDay(for: $0.date) }).sorted()
        guard days.count > 0 else { return 0 }
        var best = 0
        for (a, b) in zip(days, days.dropFirst()) {
            best = max(best, (cal.dateComponents([.day], from: a, to: b).day ?? 1) - 1)
        }
        let open = cal.dateComponents([.day], from: days.last!, to: cal.startOfDay(for: Date())).day ?? 0
        return max(best, open)
    }
}
