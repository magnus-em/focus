import Foundation
import FocusCore
import SwiftData

struct RecallCardDraft: Identifiable, Equatable {
    let id = UUID()
    var prompt: String
    var answer: String
    var kind: KnowledgeKind = .concept
    var topic: String = ""
    var include = true
}

struct RecallBucket: Identifiable {
    let label: String
    let range: Range<Double>
    let attempts: Int
    let successes: Int
    var id: String { label }
    var rate: Double? { attempts > 0 ? Double(successes) / Double(attempts) : nil }
}

struct RecallWeek: Identifiable {
    let start: Date
    let focusHours: Double
    let notes: Int
    let reviews: Int
    let unaided: Double?
    let retention: Double?
    let retentionN: Int
    var id: Date { start }
}

/// Retrieval practice: knowledge cards, their review history, and free-recall
/// notes. Scheduling lives in `RecallScheduler` (FocusCore).
final class RecallStore: ObservableObject {
    @Published private(set) var items: [StoredKnowledgeItem] = []
    @Published private(set) var attempts: [StoredRecallAttempt] = []
    @Published private(set) var notes: [StoredRecallNote] = []

    private let context: ModelContext
    private static let skippedYesterdayKey = "yesterdayRecallSkippedDay"

    init(container: ModelContainer) {
        context = ModelContext(container)
        refresh()
    }

    func refresh() {
        var i = FetchDescriptor<StoredKnowledgeItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        i.includePendingChanges = true
        var a = FetchDescriptor<StoredRecallAttempt>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        a.includePendingChanges = true
        var n = FetchDescriptor<StoredRecallNote>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        n.includePendingChanges = true
        items = (try? context.fetch(i)) ?? []
        attempts = (try? context.fetch(a)) ?? []
        notes = (try? context.fetch(n)) ?? []
    }

    private func save() {
        try? context.save()
        refresh()
    }

    // MARK: - Cards

    var activeItems: [StoredKnowledgeItem] { items.filter { !$0.archived } }

    var courses: [String] {
        Array(Set(items.map(\.course).filter { !$0.isEmpty })).sorted()
    }

    @discardableResult
    func addItem(course: String, prompt: String, answer: String, kind: KnowledgeKind = .concept,
                 topic: String = "", source: String = "", byAI: Bool = false, noteID: UUID? = nil) -> StoredKnowledgeItem {
        let it = StoredKnowledgeItem()
        it.course = course
        it.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        it.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        it.kind = kind
        it.topic = topic
        it.source = source
        it.answerByAI = byAI
        it.noteID = noteID
        it.intervalDays = RecallScheduler.firstInterval
        it.nextDue = RecallScheduler.dueDate(from: Date(), interval: RecallScheduler.firstInterval)
        context.insert(it)
        save()
        return it
    }

    func addDrafts(_ drafts: [RecallCardDraft], course: String, noteID: UUID?) {
        for d in drafts where d.include && !d.prompt.isEmpty {
            addItem(course: course, prompt: d.prompt, answer: d.answer, kind: d.kind,
                    topic: d.topic, byAI: true, noteID: noteID)
        }
    }

    func update(_ item: StoredKnowledgeItem, _ change: (StoredKnowledgeItem) -> Void) {
        change(item)
        save()
    }

    func delete(_ item: StoredKnowledgeItem) {
        let id = item.id
        try? context.delete(model: StoredRecallAttempt.self, where: #Predicate { $0.itemID == id })
        context.delete(item)
        save()
    }

    // MARK: - Review queue

    var due: [StoredKnowledgeItem] {
        let now = Date()
        return activeItems
            .filter { $0.nextDue <= now }
            .sorted {
                RecallScheduler.overdueRatio(nextDue: $0.nextDue, interval: $0.intervalDays, now: now)
                    > RecallScheduler.overdueRatio(nextDue: $1.nextDue, interval: $1.intervalDays, now: now)
            }
    }

    var reviewedToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return attempts.filter { $0.date >= start }.count
    }

    /// Today's queue: most overdue first, capped so a missed week turns into
    /// a few normal days rather than one huge backlog.
    func todayQueue(cap: Int) -> [StoredKnowledgeItem] {
        Array(due.prefix(max(0, cap - reviewedToday)))
    }

    func dueCount(cap: Int) -> Int { min(due.count, max(0, cap - reviewedToday)) }

    func nextDueDate() -> Date? {
        activeItems.map(\.nextDue).filter { $0 > Date() }.min()
    }

    func attempts(for item: StoredKnowledgeItem) -> [StoredRecallAttempt] {
        attempts.filter { $0.itemID == item.id }
    }

    func previewInterval(_ item: StoredKnowledgeItem, grade: RecallGrade, hinted: Bool) -> Double {
        RecallScheduler.nextInterval(current: item.intervalDays, grade: grade, hinted: hinted)
    }

    func record(_ item: StoredKnowledgeItem, response: String, grade: RecallGrade, hinted: Bool,
                seconds: Double, aiScore: RecallGrade?, aiFeedback: String) {
        let now = Date()
        let last = attempts(for: item).first?.date ?? item.createdAt
        let a = StoredRecallAttempt()
        a.itemID = item.id
        a.date = now
        a.response = response
        a.score = (hinted ? min(grade, .partial) : grade).rawValue
        a.hinted = hinted
        a.delayDays = now.timeIntervalSince(last) / 86400
        a.aiScore = aiScore?.rawValue ?? -1
        a.aiFeedback = aiFeedback
        a.secondsToAnswer = seconds
        context.insert(a)

        let next = RecallScheduler.nextInterval(current: item.intervalDays, grade: grade, hinted: hinted)
        item.intervalDays = next
        item.nextDue = RecallScheduler.dueDate(from: now, interval: next)
        item.reps += 1
        if grade == .forgot { item.lapses += 1 }
        save()
    }

    // MARK: - Notes

    @discardableResult
    func addNote(kind: RecallNoteKind, text: String, label: String = "", sessionStart: Date? = nil,
                 minutes: Double = 0, date: Date = Date()) -> StoredRecallNote {
        let n = StoredRecallNote()
        n.kind = kind
        n.date = date
        n.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        n.label = label
        n.sessionStart = sessionStart
        n.sessionMinutes = minutes
        context.insert(n)
        save()
        return n
    }

    func setFeedback(_ note: StoredRecallNote, _ feedback: String) {
        note.aiFeedback = feedback
        save()
    }

    func delete(_ note: StoredRecallNote) {
        context.delete(note)
        save()
    }

    func notes(on day: Date, kind: RecallNoteKind) -> [StoredRecallNote] {
        let cal = Calendar.current
        return notes.filter { $0.kind == kind && cal.isDate($0.sessionStart ?? $0.date, inSameDayAs: day) }
    }

    func cardCount(for note: StoredRecallNote) -> Int {
        items.filter { $0.noteID == note.id }.count
    }

    /// The morning yesterday-reconstruction is still open today.
    func needsYesterdayRecall(sessionStore: SessionStore) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if UserDefaults.standard.double(forKey: Self.skippedYesterdayKey) >= today.timeIntervalSince1970 { return false }
        if notes.contains(where: { $0.kind == .yesterday && $0.date >= today }) { return false }
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        return sessionStore.sessions.contains { $0.startTime >= yesterday && $0.startTime < today }
    }

    func skipYesterdayRecall() {
        UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970,
                                  forKey: Self.skippedYesterdayKey)
        objectWillChange.send()
    }

    // MARK: - Stats

    static let buckets: [(String, Range<Double>)] = [
        ("~1 day", 0..<2), ("2–5 days", 2..<5.5), ("~1 week", 5.5..<11),
        ("~2 weeks", 11..<22), ("1 month+", 22..<10_000),
    ]

    /// Unaided success by how long it had been since the last look.
    func retentionByDelay(since: Date? = nil) -> [RecallBucket] {
        let pool = attempts.filter { since == nil || $0.date >= since! }
        return Self.buckets.map { label, range in
            let inB = pool.filter { range.contains($0.delayDays) }
            return RecallBucket(label: label, range: range, attempts: inB.count,
                                successes: inB.filter(\.isUnaidedSuccess).count)
        }
    }

    func unaidedRate(_ pool: [StoredRecallAttempt]) -> Double? {
        pool.isEmpty ? nil : Double(pool.filter(\.isUnaidedSuccess).count) / Double(pool.count)
    }

    /// Oldest first, ending with the current week.
    func weeks(_ n: Int, sessionStore: SessionStore) -> [RecallWeek] {
        let cal = HealthStore.calendar
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { back in
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let wk = attempts.filter { $0.date >= start && $0.date < end }
            let delayed = wk.filter { $0.delayDays >= 5.5 }
            return RecallWeek(
                start: start,
                focusHours: sessionStore.workMinutes(since: start, until: end) / 60,
                notes: notes.filter { $0.kind == .session && $0.date >= start && $0.date < end }.count,
                reviews: wk.count,
                unaided: unaidedRate(wk),
                retention: unaidedRate(delayed),
                retentionN: delayed.count
            )
        }
    }

    /// Cards that keep slipping: most lapses, then lowest recent score.
    func hardest(limit: Int = 6) -> [StoredKnowledgeItem] {
        activeItems
            .filter { $0.reps > 0 }
            .map { item -> (StoredKnowledgeItem, Double) in
                let recent = attempts(for: item).prefix(3)
                let avg = recent.isEmpty ? 3 : Double(recent.map(\.score).reduce(0, +)) / Double(recent.count)
                return (item, Double(item.lapses) * 2 + (3 - avg))
            }
            .filter { $0.1 > 1 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Focus blocks long enough to prompt a recall vs. how many got one.
    func noteCoverage(since: Date, minMinutes: Int, sessionStore: SessionStore) -> (written: Int, eligible: Int) {
        let eligible = sessionStore.sessions.filter {
            $0.isFocus && $0.startTime >= since && $0.durationMinutes >= Double(minMinutes)
        }.count
        let written = notes.filter { $0.kind == .session && $0.date >= since }.count
        return (written, eligible)
    }
}
