import Foundation

// MARK: - Problem tracking

public enum ProblemDifficulty: String, Codable, CaseIterable, Sendable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"
}

public enum Confidence: String, Codable, CaseIterable, Sendable {
    case solid = "Got it"
    case shaky = "Shaky"
    case struggled = "Struggled"
}

public enum ProblemDomain: String, Codable, CaseIterable, Sendable {
    case quant = "Quant"
    case swe   = "SWE"

    public var categories: [String] {
        switch self {
        case .quant: return [
            "Probability", "Combinatorics", "Expected Value", "Distributions",
            "Random Walks", "Martingales", "Stochastic Calculus", "Game Theory",
            "Markov Chains", "Linear Algebra", "Statistics", "Options Math", "Brainteasers"
        ]
        case .swe: return [
            "Arrays & Hashing", "Two Pointers", "Sliding Window", "Stack",
            "Binary Search", "Linked List", "Trees", "Tries", "Heap",
            "Backtracking", "Graphs", "Dynamic Programming", "Greedy",
            "Intervals", "Bit Manipulation", "Math & Geometry"
        ]
        }
    }
}

public struct ProblemEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let title: String
    public let domain: ProblemDomain
    public let categories: [String]
    public var difficulty: ProblemDifficulty
    public var needsReview: Bool
    public var confidence: Confidence
    public var source: String
    public var notes: String
    public var url: String
    public var solveMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id, date, title, domain, categories, difficulty
        case needsReview, confidence, source, notes, url, solveMinutes
    }

    public init(title: String, domain: ProblemDomain, categories: [String],
                difficulty: ProblemDifficulty, source: String = "",
                needsReview: Bool = false, confidence: Confidence = .solid,
                notes: String = "", url: String = "", solveMinutes: Int? = nil) {
        self.id = UUID()
        self.date = Date()
        self.title = title
        self.domain = domain
        self.categories = categories
        self.difficulty = difficulty
        self.source = source
        self.needsReview = needsReview
        self.confidence = confidence
        self.notes = notes
        self.url = url
        self.solveMinutes = solveMinutes
    }

    public init(id: UUID, date: Date, title: String, domain: ProblemDomain, categories: [String],
                difficulty: ProblemDifficulty, source: String = "",
                needsReview: Bool = false, confidence: Confidence = .solid,
                notes: String = "", url: String = "", solveMinutes: Int? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.domain = domain
        self.categories = categories
        self.difficulty = difficulty
        self.source = source
        self.needsReview = needsReview
        self.confidence = confidence
        self.notes = notes
        self.url = url
        self.solveMinutes = solveMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,              forKey: .id)
        date         = try c.decode(Date.self,              forKey: .date)
        title        = try c.decode(String.self,            forKey: .title)
        domain       = try c.decode(ProblemDomain.self,     forKey: .domain)
        categories   = try c.decode([String].self,          forKey: .categories)
        difficulty   = try c.decode(ProblemDifficulty.self, forKey: .difficulty)
        needsReview  = try c.decodeIfPresent(Bool.self,        forKey: .needsReview)  ?? false
        confidence   = try c.decodeIfPresent(Confidence.self,  forKey: .confidence)   ?? .solid
        source       = try c.decodeIfPresent(String.self,      forKey: .source)       ?? ""
        notes        = try c.decodeIfPresent(String.self,      forKey: .notes)        ?? ""
        url          = try c.decodeIfPresent(String.self,      forKey: .url)          ?? ""
        solveMinutes = try c.decodeIfPresent(Int.self,         forKey: .solveMinutes)
    }

    public var reviewDueDate: Date? {
        guard confidence != .solid || needsReview else { return nil }
        let interval: TimeInterval
        if needsReview       { interval = 1 * 86400 }
        else if confidence == .struggled { interval = 1 * 86400 }
        else                 { interval = 3 * 86400 }
        return date.addingTimeInterval(interval)
    }

    public var isDueForReview: Bool {
        guard let due = reviewDueDate else { return false }
        return due <= Date()
    }
}

// MARK: - Timer sessions

public struct WorkSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let durationMinutes: Double
    public let type: SessionType
    public var label: String?
    public var breakKinds: [BreakKind]?

    public init(startTime: Date, durationMinutes: Double, type: SessionType, label: String? = nil, breakKinds: [BreakKind]? = nil) {
        self.id = UUID()
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.type = type
        self.label = label
        self.breakKinds = breakKinds
    }

    public init(id: UUID, startTime: Date, durationMinutes: Double, type: SessionType,
                label: String? = nil, breakKinds: [BreakKind]? = nil) {
        self.id = id
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.type = type
        self.label = label
        self.breakKinds = breakKinds
    }

    public enum SessionType: String, Codable, Sendable {
        case work
        case shortBreak
        case longBreak

        public var isBreak: Bool { self != .work }
    }
}

/// Focus categories (homework, prep) count toward the daily goal; life
/// categories (sleep, meals, ...) are tracked for the full-day picture only.
/// The life set lives in synced defaults under `lifeTags`.
public enum FocusCategories {
    public static let lifeTagsKey = "lifeTags"

    /// Life blocks and focus overtime carry this much runway so the shared
    /// timer state never shows an expired endTime, which peers treat as over.
    public static let openEndedSeconds: TimeInterval = 24 * 3600

    /// Until a device has received the synced list, assume these.
    public static let defaultLifeTags = ["Class", "Meals", "Leisure", "Sleep", "Chores", "Exercise", "Social", "Commute", "Admin"]

    public static func isLife(_ label: String?) -> Bool {
        guard let label, !label.isEmpty else { return false }
        return (UserDefaults.standard.stringArray(forKey: lifeTagsKey) ?? defaultLifeTags).contains(label)
    }

    // MARK: Timer display, derived only from (total, remaining) so every
    // device renders a shared state the same way.

    public static func isOpenEnded(total: TimeInterval) -> Bool { total >= openEndedSeconds }

    /// Countdown length before overtime; 0 for a life block.
    public static func countdown(total: TimeInterval) -> TimeInterval {
        total.truncatingRemainder(dividingBy: openEndedSeconds)
    }

    /// Countdown → "MM:SS" left; overtime and life → total elapsed, so
    /// finishing a block never looks like the clock reset to zero.
    public static func timeString(total: TimeInterval, remaining: TimeInterval) -> String {
        guard isOpenEnded(total: total) else { return clock(remaining, hours: false) }
        return clock(total - remaining, hours: true)
    }

    /// Seconds past the countdown target, or nil when not in overtime.
    public static func overtime(total: TimeInterval, remaining: TimeInterval) -> TimeInterval? {
        let target = countdown(total: total)
        guard isOpenEnded(total: total), target > 0 else { return nil }
        return max(0, total - remaining - target)
    }

    /// Countdown fills once; overtime and open-ended blocks stay full, since
    /// there is no target to sweep toward.
    public static func progress(total: TimeInterval, remaining: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        return isOpenEnded(total: total) ? 1 : 1.0 - remaining / total
    }

    private static func clock(_ t: TimeInterval, hours: Bool) -> String {
        let s = max(0, Int(t))
        if hours && s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension WorkSession {
    public var isFocus: Bool { type == .work && !FocusCategories.isLife(label) }
}

// MARK: - Homework problems (side system)

public struct HomeworkProblem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public var title: String
    public var source: String
    public var difficulty: ProblemDifficulty
    public var confidence: Confidence
    public var usedAI: Bool
    public var notes: String
    public var url: String
    /// Links this entry back to a `Stat110Problem` (or any future catalog).
    /// Nil for manually-typed entries; non-nil when the user picked from
    /// a course catalog — we use it to mark catalog items as "done."
    public var catalogID: String?
    /// Mark for review (mirrors ProblemEntry). Drives the review-due
    /// schedule along with `confidence`.
    public var needsReview: Bool
    /// User-overridable review date. If nil, falls back to the schedule
    /// computed from `confidence` + `needsReview`.
    public var reviewOverrideDate: Date?

    private enum CodingKeys: String, CodingKey {
        case id, date, title, source, difficulty, confidence, usedAI, notes, url
        case catalogID, needsReview, reviewOverrideDate
    }

    public init(title: String, source: String = "", difficulty: ProblemDifficulty = .medium,
                confidence: Confidence = .solid, usedAI: Bool = false,
                notes: String = "", url: String = "", catalogID: String? = nil,
                needsReview: Bool = false, reviewOverrideDate: Date? = nil) {
        self.id = UUID()
        self.date = Date()
        self.title = title
        self.source = source
        self.difficulty = difficulty
        self.confidence = confidence
        self.usedAI = usedAI
        self.notes = notes
        self.url = url
        self.catalogID = catalogID
        self.needsReview = needsReview
        self.reviewOverrideDate = reviewOverrideDate
    }

    public init(id: UUID, date: Date, title: String, source: String = "",
                difficulty: ProblemDifficulty = .medium, confidence: Confidence = .solid,
                usedAI: Bool = false, notes: String = "", url: String = "",
                catalogID: String? = nil, needsReview: Bool = false,
                reviewOverrideDate: Date? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.source = source
        self.difficulty = difficulty
        self.confidence = confidence
        self.usedAI = usedAI
        self.notes = notes
        self.url = url
        self.catalogID = catalogID
        self.needsReview = needsReview
        self.reviewOverrideDate = reviewOverrideDate
    }

    /// Decode tolerant of older JSON that doesn't have the new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,             forKey: .id)
        date         = try c.decode(Date.self,             forKey: .date)
        title        = try c.decode(String.self,           forKey: .title)
        source       = try c.decodeIfPresent(String.self,  forKey: .source)       ?? ""
        difficulty   = try c.decodeIfPresent(ProblemDifficulty.self, forKey: .difficulty) ?? .medium
        confidence   = try c.decodeIfPresent(Confidence.self,        forKey: .confidence) ?? .solid
        usedAI       = try c.decodeIfPresent(Bool.self,    forKey: .usedAI)       ?? false
        notes        = try c.decodeIfPresent(String.self,  forKey: .notes)        ?? ""
        url          = try c.decodeIfPresent(String.self,  forKey: .url)          ?? ""
        catalogID    = try c.decodeIfPresent(String.self,  forKey: .catalogID)
        needsReview  = try c.decodeIfPresent(Bool.self,    forKey: .needsReview)  ?? false
        reviewOverrideDate = try c.decodeIfPresent(Date.self, forKey: .reviewOverrideDate)
    }

    /// Spaced-repetition schedule — same shape as ProblemEntry.
    /// - Solid confidence + not marked = no review needed.
    /// - Marked for review or struggled = 1 day out.
    /// - Mid-confidence (okay / shaky) = 3 days out.
    /// - User-set override always wins.
    public var reviewDueDate: Date? {
        if let override = reviewOverrideDate { return override }
        guard confidence != .solid || needsReview else { return nil }
        let interval: TimeInterval
        if needsReview { interval = 1 * 86400 }
        else if confidence == .struggled { interval = 1 * 86400 }
        else { interval = 3 * 86400 }
        return date.addingTimeInterval(interval)
    }

    public var isDueForReview: Bool {
        guard let due = reviewDueDate else { return false }
        return due <= Date()
    }
}

public enum BreakKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case meal, workout, chill

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var icon: String {
        switch self {
        case .meal:    return "fork.knife"
        case .workout: return "figure.run"
        case .chill:   return "moon.zzz"
        }
    }
}

public struct DailySummary: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let totalWorkMinutes: Double
    public let sessionCount: Int

    public init(id: String, date: Date, totalWorkMinutes: Double, sessionCount: Int) {
        self.id = id
        self.date = date
        self.totalWorkMinutes = totalWorkMinutes
        self.sessionCount = sessionCount
    }
}

// MARK: - Day record

public struct DayRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let calendarDay: Date
    public var dayStart: Date?
    public var dayEnd: Date?
    public var commitmentText: String?
    public var commitmentFulfilled: Bool?

    public init() {
        self.id = UUID()
        self.calendarDay = Calendar.current.startOfDay(for: Date())
    }

    public init(id: UUID, calendarDay: Date, dayStart: Date? = nil, dayEnd: Date? = nil,
                commitmentText: String? = nil, commitmentFulfilled: Bool? = nil) {
        self.id = id
        self.calendarDay = calendarDay
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.commitmentText = commitmentText
        self.commitmentFulfilled = commitmentFulfilled
    }
}

// MARK: - Scratchpad

public struct ScratchItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var isChecked: Bool

    public init(text: String) {
        self.id = UUID()
        self.text = text
        self.isChecked = false
    }

    public init(id: UUID, text: String, isChecked: Bool) {
        self.id = id
        self.text = text
        self.isChecked = isChecked
    }
}
