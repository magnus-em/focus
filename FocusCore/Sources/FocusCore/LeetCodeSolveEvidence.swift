import Foundation

public enum LeetCodeSolveEvidence {
    public struct Candidate: Equatable, Sendable {
        public let slug: String, submissionID: String
        public let observedAt: Date
        public let journalRowID: UUID
        public var dailyKey: String {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: observedAt)
            return String(format: "%04d-%02d-%02d|%@", parts.year!, parts.month!, parts.day!, slug)
        }
    }
    public static func candidate(row: ScreenJournal.Row, text: String) -> Candidate? {
        guard row.privacy == .regular, ScreenJournal.hash(text) == row.textHash,
              let value = row.url, let url = URL(string:value), url.scheme == "https",
              ["leetcode.com", "www.leetcode.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path.split(separator:"/").map(String.init)
        guard path.count == 4, path[0] == "problems", path[2] == "submissions",
              path[1].count <= 160, path[1].range(of:#"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options:.regularExpression) != nil,
              !path[3].isEmpty, path[3].count <= 24, path[3].allSatisfy({ $0.isASCII && $0.isNumber }),
              text.range(of:#"(?im)^\s*(?:status\s*:\s*)?accepted\s*$"#, options:.regularExpression) != nil,
              text.range(of:#"(?i)\b(runtime|memory|submission detail|submitted|test result)\b"#, options:.regularExpression) != nil else { return nil }
        return Candidate(slug:path[1],submissionID:path[3],observedAt:row.at,journalRowID:row.id)
    }
    public static func stopwatchMinutes(slug: String, activeSlug: String?, startedAt: Date?, observedAt: Date) -> Int? {
        guard activeSlug == slug, let start = startedAt else { return nil }
        let seconds = observedAt.timeIntervalSince(start)
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 60) else { return nil }
        return max(1,Int((seconds / 60).rounded()))
    }
}
