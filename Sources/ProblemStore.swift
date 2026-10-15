import Foundation
import FocusCore
import SwiftData

class ProblemStore: ObservableObject {
    @Published var problems: [ProblemEntry] = []

    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        refresh()
    }

    private func refresh() {
        var descriptor = FetchDescriptor<StoredProblem>(
            sortBy: [SortDescriptor(\.date)]
        )
        descriptor.includePendingChanges = true
        let stored = (try? context.fetch(descriptor)) ?? []
        problems = stored.map { $0.asValue }
    }

    @discardableResult
    func add(_ entry: ProblemEntry) -> Bool {
        context.insert(StoredProblem(value: entry))
        do { try context.save(); refresh(); return true }
        catch { context.rollback(); refresh(); return false }
    }

    func clearAll() {
        try? context.delete(model: StoredProblem.self)
        try? context.save()
        refresh()
    }

    func update(_ entry: ProblemEntry) {
        let target = entry.id
        let predicate = #Predicate<StoredProblem> { $0.id == target }
        var descriptor = FetchDescriptor<StoredProblem>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try? context.fetch(descriptor).first else { return }
        model.title = entry.title
        model.domain = entry.domain
        model.categories = entry.categories
        model.difficulty = entry.difficulty
        model.needsReview = entry.needsReview
        model.confidence = entry.confidence
        model.source = entry.source
        model.notes = entry.notes
        model.urlString = entry.url
        model.solveMinutes = entry.solveMinutes
        try? context.save()
        refresh()
    }

    func delete(id: UUID) {
        let target = id
        let predicate = #Predicate<StoredProblem> { $0.id == target }
        var descriptor = FetchDescriptor<StoredProblem>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let model = try? context.fetch(descriptor).first {
            context.delete(model)
            try? context.save()
            refresh()
        }
    }

    func clearReview(id: UUID) {
        let target = id
        let predicate = #Predicate<StoredProblem> { $0.id == target }
        var descriptor = FetchDescriptor<StoredProblem>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let model = try? context.fetch(descriptor).first {
            model.needsReview = false
            try? context.save()
            refresh()
        }
    }

    // MARK: - Aggregates

    func count(for domain: ProblemDomain) -> Int {
        problems.filter { $0.domain == domain }.count
    }

    var totalCount: Int { problems.count }

    var needsReviewItems: [ProblemEntry] {
        problems.filter { $0.needsReview }.sorted { $0.date > $1.date }
    }

    func countByCategory(domain: ProblemDomain) -> [(category: String, count: Int)] {
        var dict: [String: Int] = [:]
        for p in problems where p.domain == domain {
            for cat in p.categories {
                dict[cat, default: 0] += 1
            }
        }
        return dict.map { (category: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// Problems grouped by calendar day, newest first.
    func byDay() -> [(date: Date, problems: [ProblemEntry])] {
        let calendar = Calendar.current
        var groups: [Date: [ProblemEntry]] = [:]
        for p in problems {
            let day = calendar.startOfDay(for: p.date)
            groups[day, default: []].append(p)
        }
        return groups.map { (date: $0.key, problems: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    /// Count per day for the last N days (oldest → newest), including zero-count days.
    func dailyCounts(days: Int) -> [(date: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let count = problems.filter { cal.startOfDay(for: $0.date) == day }.count
            return (date: day, count: count)
        }
    }

    var thisWeekCount: Int {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        return problems.filter { $0.date >= start }.count
    }

    var lastWeekCount: Int {
        let cal = Calendar.current
        let thisStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        let lastStart = cal.date(byAdding: .day, value: -7, to: thisStart)!
        return problems.filter { $0.date >= lastStart && $0.date < thisStart }.count
    }

    /// Fraction of all problems logged without AI help.
    var cleanSolveRate: Double {
        guard !problems.isEmpty else { return 1.0 }
        return Double(problems.filter { !$0.needsReview }.count) / Double(problems.count)
    }

    func countByDifficulty() -> [(difficulty: ProblemDifficulty, count: Int)] {
        ProblemDifficulty.allCases.map { d in
            (difficulty: d, count: problems.filter { $0.difficulty == d }.count)
        }
    }

    func countByConfidence() -> [(confidence: Confidence, count: Int)] {
        Confidence.allCases.map { c in
            (confidence: c, count: problems.filter { $0.confidence == c }.count)
        }
    }

    // MARK: - Streak

    var problemStreak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        // If today is empty, start counting from yesterday
        if !problems.contains(where: { cal.startOfDay(for: $0.date) == day }) {
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while problems.contains(where: { cal.startOfDay(for: $0.date) == day }) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    // MARK: - Weak areas

    /// Categories ranked by lowest average confidence (min 2 attempts).
    func weakestCategories(limit: Int = 3) -> [(category: String, avgScore: Double, count: Int)] {
        var data: [String: (score: Double, count: Int)] = [:]
        for p in problems {
            let score: Double
            switch p.confidence {
            case .solid:     score = 2.0
            case .shaky:     score = 1.0
            case .struggled: score = 0.0
            }
            for cat in p.categories {
                let cur = data[cat] ?? (0, 0)
                data[cat] = (cur.score + score, cur.count + 1)
            }
        }
        return data
            .filter { $0.value.count >= 2 }
            .map { (category: $0.key, avgScore: $0.value.score / Double($0.value.count), count: $0.value.count) }
            .sorted { $0.avgScore < $1.avgScore }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Spaced repetition

    var dueForReview: [ProblemEntry] {
        problems.filter { $0.isDueForReview }.sorted { $0.date < $1.date }
    }
}
