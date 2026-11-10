import Foundation

/// What you're working toward, in priority order, editable any time
/// (synced key `goals.v1`). Insights rank what they say by these, and goals
/// marked `avoided` (the work you put off) get measured and nudged first.
/// Every edit is kept with its date so a report can say "since you made
/// recruiting #1 on Nov 9".
public enum Goals {
    public static let key = "goals.v1"

    public enum Output: String, Codable, CaseIterable, Sendable, Identifiable {
        case applications, leetCodeProblems
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .applications: "Applications sent"
            case .leetCodeProblems: "LeetCode problems"
            }
        }
    }

    public struct Goal: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var title: String
        public var why: String
        /// Categories whose time counts toward it.
        public var categories: [String]
        /// Course codes whose time counts toward it (wins over category).
        public var courses: [String]
        public var weeklyHours: Double?
        /// A day with less than this on an avoided goal gets one nudge.
        public var dailyMinutes: Double?
        public var outputs: [Output]
        public var outputsPerWeek: [String: Int]
        /// Work you tend to put off; measured and nudged first.
        public var avoided: Bool
        public var deadline: Date?
        public var archived: Bool
        public var createdAt: Date
        public var updatedAt: Date

        public init(id: UUID = UUID(), title: String, why: String = "", categories: [String] = [], courses: [String] = [],
                    weeklyHours: Double? = nil, dailyMinutes: Double? = nil, outputs: [Output] = [],
                    outputsPerWeek: [String: Int] = [:], avoided: Bool = false, deadline: Date? = nil,
                    archived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
            self.id = id; self.title = title; self.why = why; self.categories = categories; self.courses = courses
            self.weeklyHours = weeklyHours; self.dailyMinutes = dailyMinutes; self.outputs = outputs
            self.outputsPerWeek = outputsPerWeek; self.avoided = avoided; self.deadline = deadline
            self.archived = archived; self.createdAt = createdAt; self.updatedAt = updatedAt
        }
    }

    public struct Change: Codable, Equatable, Sendable {
        public var at: Date
        public var summary: String
        public init(at: Date, summary: String) { self.at = at; self.summary = summary }
    }

    public struct Document: Codable, Equatable, Sendable {
        /// Priority order: first is the top goal.
        public var goals: [Goal]
        public var history: [Change]
        /// When you last went through them (the weekly review).
        public var reviewedAt: Date?
        public init(goals: [Goal], history: [Change] = [], reviewedAt: Date? = nil) {
            self.goals = goals; self.history = history; self.reviewedAt = reviewedAt
        }

        public var active: [Goal] { goals.filter { !$0.archived } }

        public func encoded() -> String? {
            (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
        }

        public static func decode(_ s: String?) -> Document? {
            guard let s else { return nil }
            return try? JSONDecoder().decode(Document.self, from: Data(s.utf8))
        }
    }

    /// Where things stood on 11/9, from what you said: recruiting first,
    /// homework second (both the work you put off), deep learning third
    /// (no target: it already gets the time).
    public static func seed(now: Date = Date()) -> Document {
        Document(goals: [
            Goal(title: "Recruiting", why: "Land a summer internship (SWE or quant).",
                 categories: ["Recruiting", "LeetCode"], weeklyHours: 6, dailyMinutes: 30,
                 outputs: [.applications, .leetCodeProblems], outputsPerWeek: ["applications": 10, "leetCodeProblems": 7],
                 avoided: true, createdAt: now, updatedAt: now),
            Goal(title: "Homework", why: "Problem sets done early, not the night they're due.",
                 categories: ["HW", "Math"], courses: ["MATH 244", "CPSC 3231", "CPSC 4585"], weeklyHours: 10,
                 dailyMinutes: 45, avoided: true, createdAt: now, updatedAt: now),
            Goal(title: "Deep learning", why: "CPSC 7770 and building models from scratch.",
                 categories: ["AI"], courses: ["CPSC 7770"], createdAt: now, updatedAt: now),
        ], history: [Change(at: now, summary: "Started with Recruiting, Homework, Deep learning")])
    }

    /// The highest goal this time counts toward: a course match first, then category.
    public static func goal(for category: String?, course: String?, in goals: [Goal]) -> Goal? {
        let active = goals.filter { !$0.archived }
        if let course, let g = active.first(where: { $0.courses.contains(course) }) { return g }
        if let category, let g = active.first(where: { $0.categories.contains(category) }) { return g }
        return nil
    }

    /// Plain-words summary of an edit, for the history.
    public static func describe(from old: Document, to new: Document) -> [String] {
        var out: [String] = []
        let oldIDs = old.active.map(\.id), newIDs = new.active.map(\.id)
        let byOld = Dictionary(uniqueKeysWithValues: old.goals.map { ($0.id, $0) })
        for g in new.active where byOld[g.id] == nil || byOld[g.id]!.archived { out.append("Added \(g.title)") }
        for g in old.active where !newIDs.contains(g.id) { out.append("Dropped \(g.title)") }
        let kept = newIDs.filter { oldIDs.contains($0) }
        let oldOrder = oldIDs.filter { kept.contains($0) }
        if kept != oldOrder, let top = new.active.first {
            out.append("Reordered: \(new.active.map(\.title).joined(separator: " > "))")
            if top.id != old.active.first?.id { out.append("Made \(top.title) #1") }
        }
        for g in new.active {
            guard let o = byOld[g.id], !o.archived else { continue }
            if o.title != g.title { out.append("Renamed \(o.title) to \(g.title)") }
            if o.weeklyHours != g.weeklyHours {
                out.append("\(g.title): weekly target \(g.weeklyHours.map { "\(fmt($0)) h" } ?? "none")")
            }
            if o.dailyMinutes != g.dailyMinutes {
                out.append("\(g.title): daily minimum \(g.dailyMinutes.map { "\(Int($0)) min" } ?? "none")")
            }
            if o.avoided != g.avoided { out.append("\(g.title): \(g.avoided ? "marked as put off" : "no longer marked as put off")") }
            if o.categories != g.categories || o.courses != g.courses { out.append("\(g.title): changed what counts") }
            if o.outputsPerWeek != g.outputsPerWeek || o.outputs != g.outputs { out.append("\(g.title): changed output targets") }
            if o.deadline != g.deadline { out.append("\(g.title): deadline \(g.deadline.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "removed")") }
            if o.why != g.why { out.append("\(g.title): reworded why") }
        }
        return out
    }

    static func fmt(_ h: Double) -> String { h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h) }
}
