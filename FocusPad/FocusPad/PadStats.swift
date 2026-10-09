import Foundation
import FocusCore

/// Pure-function stats helpers used by Dashboard & Stats screens.
/// All functions accept an array of `StoredWorkSession` (or `StoredProblem`).
enum PadStats {
    static var cal: Calendar { Calendar.current }

    // MARK: - Per-day work minutes

    static func workMinutes(_ sessions: [StoredWorkSession], on day: Date) -> Double {
        sessions
            .filter { cal.isDate($0.startTime, inSameDayAs: day) && $0.isFocus }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    static func breakMinutes(_ sessions: [StoredWorkSession], on day: Date) -> Double {
        sessions
            .filter { cal.isDate($0.startTime, inSameDayAs: day) && $0.type.isBreak }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    static func sessionCount(_ sessions: [StoredWorkSession], on day: Date) -> Int {
        sessions.filter { cal.isDate($0.startTime, inSameDayAs: day) && $0.isFocus }.count
    }

    // MARK: - Recent windows

    /// minutes per day, dictionary keyed by start-of-day, for the last `days` days.
    static func minutesByDay(_ sessions: [StoredWorkSession], days: Int) -> [Date: Double] {
        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let work = sessions.filter { $0.isFocus && $0.startTime >= earliest }
        var dict: [Date: Double] = [:]
        for s in work {
            let day = cal.startOfDay(for: s.startTime)
            dict[day, default: 0] += s.durationMinutes
        }
        return dict
    }

    static func lastNDaysMinutes(_ sessions: [StoredWorkSession], days: Int) -> [(Date, Double)] {
        let by = minutesByDay(sessions, days: days)
        let today = cal.startOfDay(for: Date())
        return (0..<days).map { i -> (Date, Double) in
            let d = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
            return (d, by[d] ?? 0)
        }
    }

    // MARK: - Streak / consistency / best week

    /// Streak of consecutive days (today inclusive) with ≥ 1 work session.
    static func currentStreak(_ sessions: [StoredWorkSession]) -> Int {
        let by = minutesByDay(sessions, days: 365)
        var streak = 0
        var day = cal.startOfDay(for: Date())
        while (by[day] ?? 0) > 0 {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    /// Best streak ever (entire history).
    static func bestStreak(_ sessions: [StoredWorkSession]) -> Int {
        let by = minutesByDay(sessions, days: 5000) // ~13 years
        let days = by.keys.sorted()
        var best = 0, run = 0
        var prev: Date? = nil
        for d in days where (by[d] ?? 0) > 0 {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            prev = d
        }
        return best
    }

    /// % of last N days with any work session.
    static func consistencyScore(_ sessions: [StoredWorkSession], days: Int) -> Double {
        let by = minutesByDay(sessions, days: days)
        let today = cal.startOfDay(for: Date())
        var hit = 0
        for i in 0..<days {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            if (by[d] ?? 0) > 0 { hit += 1 }
        }
        return Double(hit) / Double(days)
    }

    /// Highest rolling-7-day window of work minutes.
    static func bestWeekMinutes(_ sessions: [StoredWorkSession]) -> Double {
        let arr = lastNDaysMinutes(sessions, days: 60)
        let values = arr.map(\.1)
        if values.count < 7 { return values.reduce(0, +) }
        var best: Double = 0
        for i in 0...(values.count - 7) {
            let window = values[i..<(i + 7)].reduce(0, +)
            best = max(best, window)
        }
        return best
    }

    // MARK: - Week-over-week

    static func weekMinutes(_ sessions: [StoredWorkSession], weeksAgo: Int) -> Double {
        let today = cal.startOfDay(for: Date())
        let startOffset = weeksAgo * 7 + 6
        let endOffset = weeksAgo * 7
        let start = cal.date(byAdding: .day, value: -startOffset, to: today)!
        let endExclusive = cal.date(byAdding: .day, value: -endOffset + 1, to: today)!
        return sessions
            .filter { $0.isFocus && $0.startTime >= start && $0.startTime < endExclusive }
            .reduce(0) { $0 + $1.durationMinutes }
    }

    // MARK: - Focus by tag

    static func byTag(_ sessions: [StoredWorkSession], days: Int = 7) -> [(tag: String, minutes: Double)] {
        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let work = sessions.filter { $0.isFocus && $0.startTime >= earliest }
        var dict: [String: Double] = [:]
        for s in work {
            let key = (s.label?.isEmpty == false ? s.label! : "Untagged")
            dict[key, default: 0] += s.durationMinutes
        }
        return dict.map { (tag: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }
    }

    // MARK: - Problems

    static func problemsByDay(_ problems: [StoredProblem], days: Int) -> [Date: Int] {
        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        var dict: [Date: Int] = [:]
        for p in problems where p.date >= earliest {
            dict[cal.startOfDay(for: p.date), default: 0] += 1
        }
        return dict
    }

    static func problemsToday(_ problems: [StoredProblem]) -> Int {
        problems.filter { cal.isDateInToday($0.date) }.count
    }

    static func problemsThisWeek(_ problems: [StoredProblem]) -> Int {
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        return problems.filter { $0.date >= weekStart }.count
    }

    // MARK: - Formatters

    static func fmtMinutes(_ m: Double) -> String {
        let total = Int(m.rounded())
        let h = total / 60
        let mn = total % 60
        if h == 0 { return "\(mn)m" }
        if mn == 0 { return "\(h)h" }
        return "\(h)h \(mn)m"
    }

    static func fmtHoursOnly(_ m: Double) -> String {
        let h = m / 60.0
        if h >= 10 { return String(format: "%.0fh", h) }
        return String(format: "%.1fh", h)
    }
}
