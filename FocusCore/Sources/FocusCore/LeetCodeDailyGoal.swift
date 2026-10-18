import Foundation

public enum LeetCodeDailyGoal {
    public struct Summary: Equatable, Sendable {
        public let new: Int
        public let redo: Int
        public var total: Int { new + redo }
    }

    public static func count(_ problems: [ProblemEntry], on day: Date, calendar: Calendar = .current) -> Int {
        summary(problems, on: day, calendar: calendar).total
    }

    public static func summary(_ problems: [ProblemEntry], on day: Date, calendar: Calendar = .current) -> Summary {
        let start = calendar.startOfDay(for: day)
        var earlier = Set<String>(), today = Set<String>()
        for entry in problems {
            guard let key = problemKey(entry) else { continue }
            if entry.date < start { earlier.insert(key) }
            else if calendar.isDate(entry.date, inSameDayAs: day) { today.insert(key) }
        }
        return Summary(new: today.subtracting(earlier).count, redo: today.intersection(earlier).count)
    }

    private static func problemKey(_ entry: ProblemEntry) -> String? {
        guard entry.domain == .swe else { return nil }
        let url = URL(string: entry.url)
        let host = url?.host?.lowercased() ?? ""
        let parts = url?.pathComponents ?? []
        if (host == "leetcode.com" || host.hasSuffix(".leetcode.com")),
           let index = parts.firstIndex(of: "problems"), parts.indices.contains(index + 1) {
            return parts[index + 1].lowercased()
        }
        if let known = Grind75Catalog.problem(matching: entry) { return known.slug }
        guard entry.source.caseInsensitiveCompare("LeetCode") == .orderedSame else { return nil }
        let title = entry.title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return title.isEmpty ? nil : title
    }

    public static func isMet(problems: Int, minutes: Double, problemGoal: Int, minutesGoal: Int) -> Bool {
        problems >= max(1, problemGoal) && minutes.isFinite && minutes >= Double(max(1, minutesGoal))
    }
}
