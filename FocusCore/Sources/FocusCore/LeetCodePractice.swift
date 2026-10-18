import Foundation

public enum LeetCodePracticeEvidence {
    public static func slug(url value: String?, privacy: ScreenJournal.Privacy, active: Bool) -> String? {
        guard active, privacy == .regular, let value, let url = URL(string: value),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              ["leetcode.com", "www.leetcode.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "problems", parts[1].count <= 160,
              parts[1].range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return parts[1]
    }
}

public struct LeetCodePracticeState: Codable, Equatable, Sendable {
    public struct Details: Codable, Equatable, Sendable {
        public var title: String
        public var difficulty: ProblemDifficulty?
        public var categories: [String]
        public var solved: Bool?
        public var confidence: Confidence?
        public var minutes: Int?
        public var usedHelp: Bool
        public var notes: String
        public init(title: String, difficulty: ProblemDifficulty?, categories: [String], solved: Bool?, confidence: Confidence?, minutes: Int?, usedHelp: Bool, notes: String) {
            self.title = title; self.difficulty = difficulty; self.categories = categories; self.solved = solved
            self.confidence = confidence; self.minutes = minutes; self.usedHelp = usedHelp; self.notes = notes
        }
    }
    public struct Session: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let slug: String
        public var title: String
        public let startedAt: Date
        public var seconds: Double = 0
        public var finishedAt: Date?
        public var outcome: Outcome = .draft
        public var confidence: Confidence?
        public var usedHelp: Bool = false
        public var notes: String = ""
        public var difficulty: ProblemDifficulty?
        public var categories: [String] = []
        public var loggedMinutes: Int?
        public var draftDetails: Details?
        public var minutes: Int? { seconds > 0 ? max(1, Int((seconds / 60).rounded())) : nil }
    }
    public enum Outcome: String, Codable, Sendable { case draft, solved, unsolved }
    public private(set) var sessions: [Session] = []
    public private(set) var activeID: UUID?
    private var lastTick: Date?
    private var wasTracking = false
    private var suppressed: [String: Date] = [:]

    public init() {}
    public var active: Session? { sessions.first { $0.id == activeID } }
    public var isTracking: Bool { wasTracking && active != nil }

    public mutating func restore() {
        lastTick = nil
        wasTracking = false
    }

    public mutating func update(at now: Date, tracking: Bool) {
        if wasTracking, let lastTick, let index = sessions.firstIndex(where: { $0.id == activeID }), sessions[index].finishedAt == nil {
            let delta = now.timeIntervalSince(lastTick)
            // The one-second worker must not turn a suspended app or sleeping Mac into work.
            if delta >= 0 && delta <= 5 { sessions[index].seconds += delta }
        }
        lastTick = now
        wasTracking = tracking && active != nil
    }

    public mutating func observePage(slug: String?) {
        suppressed = suppressed.filter { $0.key == slug }
    }

    @discardableResult
    public mutating func select(slug: String, title: String, at now: Date, automatic: Bool = false) -> Bool {
        if automatic, let date = suppressed[slug], Calendar.current.isDate(date, inSameDayAs: now) { return false }
        if active?.slug == slug { return true }
        update(at: now, tracking: false)
        if let existing = sessions.last(where: { $0.slug == slug && $0.outcome == .draft && $0.finishedAt == nil }) {
            activeID = existing.id
        } else {
            let session = Session(id: UUID(), slug: slug, title: title, startedAt: now)
            sessions.append(session)
            activeID = session.id
        }
        if !automatic { suppressed.removeValue(forKey: slug) }
        return true
    }

    @discardableResult
    public mutating func finish(at now: Date) -> Session? {
        update(at: now, tracking: false)
        guard let index = sessions.firstIndex(where: { $0.id == activeID }) else { return nil }
        sessions[index].finishedAt = now
        suppressed[sessions[index].slug] = now
        activeID = nil
        return sessions[index]
    }

    public mutating func prepareLog(id: UUID, at now: Date) -> Session? {
        if activeID == id { return finish(at: now) }
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.outcome == .draft }) else { return nil }
        if sessions[index].finishedAt == nil { sessions[index].finishedAt = now }
        suppressed[sessions[index].slug] = now
        return sessions[index]
    }

    public mutating func resume(id: UUID, at now: Date) {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.outcome == .draft }) else { return }
        update(at: now, tracking: false)
        sessions[index].finishedAt = nil
        activeID = id
        suppressed.removeValue(forKey: sessions[index].slug)
    }

    public mutating func keepDetails(id: UUID, details: Details) {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.outcome == .draft }) else { return }
        sessions[index].draftDetails = details
    }

    public mutating func complete(id: UUID, solved: Bool, confidence: Confidence, usedHelp: Bool, notes: String, title: String, difficulty: ProblemDifficulty? = nil, categories: [String] = [], minutes: Int? = nil) {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.outcome == .draft }) else { return }
        sessions[index].outcome = solved ? .solved : .unsolved
        sessions[index].draftDetails = nil
        sessions[index].confidence = confidence
        sessions[index].usedHelp = usedHelp
        sessions[index].notes = notes
        sessions[index].title = title
        sessions[index].difficulty = difficulty
        sessions[index].categories = categories
        sessions[index].loggedMinutes = minutes
    }

    public mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-60 * 86400)
        sessions.removeAll { $0.id != activeID && $0.outcome != .draft && ($0.finishedAt ?? $0.startedAt) < cutoff }
        suppressed = suppressed.filter { Calendar.current.isDate($0.value, inSameDayAs: now) }
    }
}
