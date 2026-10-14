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

    struct Exam: Identifiable {
        let title: String
        let date: Date
        /// From the course code: MATH → Math, CPSC/CS → SWE; nil = unknown.
        let category: String?
        var id: String { "\(title)|\(date.timeIntervalSince1970)" }
    }
    /// Exams, midterms and finals in the next 30 days.
    @Published private(set) var exams: [Exam] = []
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

    /// The latest class that ended after `start` (while Class was running) and
    /// isn't followed by one still going.
    func endedClass(since start: Date, now: Date = Date()) -> EKEvent? {
        guard currentClass(at: now) == nil else { return nil }
        return today.filter { $0.endDate <= now && $0.endDate > start }.max { $0.endDate < $1.endDate }
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
        let ahead = store.events(matching: store.predicateForEvents(
            withStart: Date(), end: cal.date(byAdding: .day, value: 30, to: start)!, calendars: nil))
        // "3231 Exam 1" names only the number; the class events say "CPSC 3231".
        let around = store.events(matching: store.predicateForEvents(
            withStart: cal.date(byAdding: .day, value: -14, to: start)!, end: cal.date(byAdding: .day, value: 30, to: start)!, calendars: nil))
        var prefixes: [String: String] = [:]
        for e in around {
            let t = (e.title ?? "").uppercased()
            if let r = t.range(of: #"\b[A-Z]{2,4} ?\d{3,4}\b"#, options: .regularExpression) {
                let code = String(t[r])
                let number = code.filter(\.isNumber), letters = code.filter(\.isLetter)
                prefixes[number] = letters
            }
        }
        exams = ahead.compactMap { e in
            let title = e.title ?? ""
            // "PSET 5 — start after exam" mentions an exam; it isn't one.
            guard title.range(of: #"(?i)\b(exam|midterm|final)\b"#, options: .regularExpression) != nil,
                  title.range(of: #"(?i)\b(review session|office hours|pset|problem set|homework|hw|due|after (the )?exam|study|prep)\b"#,
                              options: .regularExpression) == nil else { return nil }
            var category = Self.category(for: title)
            if category == nil, let r = title.range(of: #"\b\d{3,4}\b"#, options: .regularExpression),
               let letters = prefixes[String(title[r])] {
                category = Self.category(for: "\(letters) \(title[r])")
            }
            return Exam(title: title, date: e.startDate, category: category)
        }
        .sorted { $0.date < $1.date }
        // The same exam on two calendars (school + personal) shows once.
        var seen = Set<String>()
        exams = exams.filter { seen.insert($0.id).inserted }
        status = today.isEmpty ? "No classes on your calendar today"
            : "\(today.count) class\(today.count == 1 ? "" : "es") today: " + today.map { $0.title ?? "" }.joined(separator: ", ")
    }

    nonisolated static func category(for title: String) -> String? {
        let t = title.uppercased()
        if t.range(of: #"\bMATH ?\d|\bDISCRETE\b|\bMATH\b|\bLINEAR ALGEBRA\b|\bCALCULUS\b|\bPROBABILITY\b"#, options: .regularExpression) != nil { return "Math" }
        if t.range(of: #"\b(CPSC|CS) ?\d|\bSYSTEMS\b|\bALGORITHMS\b"#, options: .regularExpression) != nil { return "SWE" }
        if t.range(of: #"\bAI\b|\bMACHINE LEARNING\b|\bML\b"#, options: .regularExpression) != nil { return "AI" }
        return nil
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
