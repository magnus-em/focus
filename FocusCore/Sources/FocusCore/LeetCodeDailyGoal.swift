import Foundation

public enum LeetCodeDailyGoal {
    public static func count(_ problems: [ProblemEntry], on day: Date, calendar: Calendar = .current) -> Int {
        problems.filter { entry in
            guard entry.domain == .swe, calendar.isDate(entry.date, inSameDayAs: day) else { return false }
            let host = URL(string: entry.url)?.host?.lowercased() ?? ""
            return host == "leetcode.com" || host.hasSuffix(".leetcode.com")
                || entry.source.caseInsensitiveCompare("LeetCode") == .orderedSame
                || Grind75Catalog.problem(matching: entry) != nil
        }.count
    }
}
