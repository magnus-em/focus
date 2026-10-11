import Foundation

public enum KnowledgeKind: String, CaseIterable, Sendable {
    case concept, derivation, algorithm, code, comparison, application, vocabulary

    public var displayName: String {
        switch self {
        case .concept: return "Explain"
        case .derivation: return "Derive"
        case .algorithm: return "Algorithm"
        case .code: return "Implement"
        case .comparison: return "Compare"
        case .application: return "Apply"
        case .vocabulary: return "Word"
        }
    }

    public var icon: String {
        switch self {
        case .concept: return "text.bubble"
        case .derivation: return "function"
        case .algorithm: return "point.3.connected.trianglepath.dotted"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .comparison: return "arrow.left.arrow.right"
        case .application: return "lightbulb"
        case .vocabulary: return "character.book.closed"
        }
    }
}

public enum RecallNoteKind: String, Sendable {
    case session, yesterday
}

public enum RecallGrade: Int, CaseIterable, Sendable {
    /// Couldn't produce it — even if it looks familiar once revealed.
    case forgot = 0
    /// Gaps, errors, or needed a hint.
    case partial = 1
    /// Correct and unaided.
    case got = 2
    /// Correct, quick, could teach it.
    case fluent = 3

    public var displayName: String {
        switch self {
        case .forgot: return "Forgot"
        case .partial: return "Partial"
        case .got: return "Got it"
        case .fluent: return "Fluent"
        }
    }

    public var detail: String {
        switch self {
        case .forgot: return "couldn't produce it"
        case .partial: return "gaps, errors or hint"
        case .got: return "correct, unaided"
        case .fluent: return "fast, could teach it"
        }
    }
}

/// Expanding-interval scheduler: 1 → 3 → 7 → 14 → 30 → 60… days.
/// Success climbs a rung (fluent climbs two), a partial or hinted answer
/// drops a rung, forgetting restarts at one day.
public enum RecallScheduler {
    public static let ladder: [Double] = [1, 3, 7, 14, 30, 60, 120, 240]
    public static let firstInterval: Double = 1

    public static func nextInterval(current: Double, grade: RecallGrade, hinted: Bool) -> Double {
        let g: RecallGrade = hinted ? min(grade, .partial) : grade
        switch g {
        case .forgot:
            return 1
        case .partial:
            return ladder.last(where: { $0 < current - 0.01 }) ?? 1
        case .got:
            return rung(above: current, steps: 1)
        case .fluent:
            return rung(above: current, steps: 2)
        }
    }

    private static func rung(above current: Double, steps: Int) -> Double {
        guard let i = ladder.firstIndex(where: { $0 > current + 0.01 }) else {
            return min(365, current * pow(2, Double(steps)))
        }
        return ladder[min(ladder.count - 1, i + steps - 1)]
    }

    /// Due on the calendar day `interval` days after `from`, from its start.
    public static func dueDate(from: Date, interval: Double, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: from)
        return calendar.date(byAdding: .day, value: max(1, Int(interval.rounded())), to: day) ?? day
    }

    /// How overdue relative to its interval — 0 when due today, 1 when a
    /// full interval late. The review queue goes most-overdue first.
    public static func overdueRatio(nextDue: Date, interval: Double, now: Date = Date()) -> Double {
        now.timeIntervalSince(nextDue) / (max(1, interval) * 86400)
    }
}

extension RecallGrade: Comparable {
    public static func < (a: RecallGrade, b: RecallGrade) -> Bool { a.rawValue < b.rawValue }
}
