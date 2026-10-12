import EventKit
import Foundation

/// Reads the Mac's calendars (Google/Yale accounts added in Internet Accounts)
/// to know when you're in class. A class is a timed, busy event that looks
/// like coursework: a course code in the title ("CPSC 3231"), an instructor or
/// CRN in the notes, or an exam/midterm/quiz. Rugby, reminders and
/// free/optional sit-ins don't count.
@MainActor
final class ClassCalendar: ObservableObject {
    static let shared = ClassCalendar()

    @Published private(set) var status = "Not connected"
    private let store = EKEventStore()
    private var today: [EKEvent] = []
    private var loadedAt = Date.distantPast
    private var authorized = false

    func start() {
        Task {
            authorized = (try? await store.requestFullAccessToEvents()) ?? false
            refresh()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The class happening at `date`, if any.
    func currentClass(at date: Date = Date()) -> EKEvent? {
        if date.timeIntervalSince(loadedAt) > 300 || !Calendar.current.isDate(loadedAt, inSameDayAs: date) { refresh() }
        return today.first { $0.startDate <= date && $0.endDate > date }
    }

    private func refresh() {
        loadedAt = Date()
        guard authorized else {
            status = "No calendar access (System Settings → Privacy & Security → Calendars)"
            today = []
            return
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let events = store.events(matching: store.predicateForEvents(
            withStart: start, end: cal.date(byAdding: .day, value: 1, to: start)!, calendars: nil))
        today = events.filter(Self.isClass).sorted { $0.startDate < $1.startDate }
        status = today.isEmpty ? "No classes on your calendar today"
            : "\(today.count) class\(today.count == 1 ? "" : "es") today: " + today.map { $0.title ?? "" }.joined(separator: ", ")
    }

    nonisolated static func isClass(_ e: EKEvent) -> Bool {
        guard !e.isAllDay, e.availability != .free, e.endDate.timeIntervalSince(e.startDate) <= 4 * 3600 else { return false }
        let title = e.title ?? ""
        let notes = e.notes ?? ""
        if title.range(of: #"\b[A-Z]{3,4} ?\d{3,4}\b"#, options: .regularExpression) != nil,
           !title.localizedCaseInsensitiveContains("due"), !title.localizedCaseInsensitiveContains("pset") { return true }
        if title.range(of: #"(?i)\b(exam|midterm|quiz|lecture|seminar|section)\b"#, options: .regularExpression) != nil { return true }
        return notes.range(of: #"(?i)\b(instructor|CRN)\b"#, options: .regularExpression) != nil
    }
}
