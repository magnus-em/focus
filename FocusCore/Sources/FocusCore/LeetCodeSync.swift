import Foundation

/// What LeetCode says was accepted, and which of it Focus hasn't logged yet.
/// The public API needs no login but only returns the 20 most recent accepted submissions;
/// the full history comes from the Chrome extension, which asks LeetCode with the user's login.
public enum LeetCodeSync {
    public struct Accepted: Equatable, Sendable {
        public let slug: String
        public let title: String
        public let date: Date
        public init(slug: String, title: String, date: Date) { self.slug = slug; self.title = title; self.date = date }
    }

    public struct Profile: Equatable, Sendable {
        public let username: String
        public let solved: Int
        public let easy: Int, medium: Int, hard: Int
        public let accepted: [Accepted]
    }

    public struct Logged: Sendable {
        public let id: UUID
        /// nil when the entry's URL/title doesn't match a catalog problem.
        public let slug: String?
        public let date: Date
        public let fromLeetCode: Bool
        public init(id: UUID, slug: String?, date: Date, fromLeetCode: Bool) {
            self.id = id; self.slug = slug; self.date = date; self.fromLeetCode = fromLeetCode
        }
    }

    public enum Action: Equatable, Sendable {
        case add(Accepted)
        /// A hand-typed LeetCode entry that day that matches no problem ("Course Scheduler 1") is this one.
        case repair(id: UUID, Accepted)
    }

    public enum SyncError: Error, Equatable { case noSuchUser, unreadable }

    /// Submissions this recent are left to the Accepted card and Done flow, which ask how it went.
    public static let settle: TimeInterval = 3600

    public static func request(username: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://leetcode.com/graphql")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("https://leetcode.com", forHTTPHeaderField: "Referer")
        let query = """
        query($u: String!) { matchedUser(username: $u) { username submitStatsGlobal { acSubmissionNum { difficulty count } } } \
        recentAcSubmissionList(username: $u, limit: 20) { title titleSlug timestamp } }
        """
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": ["u": username]])
        return r
    }

    public static func decode(_ data: Data) throws -> Profile {
        struct Body: Decodable {
            struct DataPart: Decodable {
                struct User: Decodable {
                    struct Stats: Decodable { struct Count: Decodable { let difficulty: String; let count: Int }; let acSubmissionNum: [Count] }
                    let username: String
                    let submitStatsGlobal: Stats
                }
                struct Sub: Decodable { let title: String; let titleSlug: String; let timestamp: String }
                let matchedUser: User?
                let recentAcSubmissionList: [Sub]?
            }
            let data: DataPart?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let part = body.data else { throw SyncError.unreadable }
        guard let user = part.matchedUser else { throw SyncError.noSuchUser }
        let counts = Dictionary(user.submitStatsGlobal.acSubmissionNum.map { ($0.difficulty, $0.count) }, uniquingKeysWith: { a, _ in a })
        let accepted = (part.recentAcSubmissionList ?? []).compactMap { s -> Accepted? in
            guard let t = Double(s.timestamp) else { return nil }
            return Accepted(slug: s.titleSlug, title: s.title, date: Date(timeIntervalSince1970: t))
        }
        return Profile(username: user.username, solved: counts["All"] ?? 0, easy: counts["Easy"] ?? 0,
                       medium: counts["Medium"] ?? 0, hard: counts["Hard"] ?? 0, accepted: accepted)
    }

    /// What the extension posts to `/leetcode`: every solved problem and each accepted submission.
    public struct History: Equatable, Sendable {
        public let signedIn: Bool
        public let username: String
        public let solved: [String: String]
        public let accepted: [Accepted]
        /// false when paging stopped early (rate limit, network), so some older accepts may be missing.
        public let complete: Bool
        public let error: String?

        /// Solved problems with no accepted submission in the history, so no date to log them at.
        public var undated: [String] { solved.keys.filter { slug in !accepted.contains { $0.slug == slug } }.sorted() }
    }

    public static func decodeHistory(_ data: Data) throws -> History {
        struct Body: Decodable {
            struct Problem: Decodable { let slug: String; let title: String }
            struct Sub: Decodable { let slug: String?; let title: String?; let timestamp: Double }
            let signedIn: Bool?
            let username: String?
            let solved: [Problem]?
            let accepted: [Sub]?
            let complete: Bool?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw SyncError.unreadable }
        let solved = Dictionary((body.solved ?? []).map { ($0.slug, $0.title) }, uniquingKeysWith: { a, _ in a })
        let slugByTitle = Dictionary(solved.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        let accepted = (body.accepted ?? []).compactMap { s -> Accepted? in
            let title = s.title ?? ""
            guard let slug = s.slug.flatMap({ $0.isEmpty ? nil : $0 }) ?? slugByTitle[title.lowercased()], s.timestamp > 0 else { return nil }
            return Accepted(slug: slug, title: title.isEmpty ? solved[slug] ?? slug : title, date: Date(timeIntervalSince1970: s.timestamp))
        }
        return History(signedIn: body.signedIn ?? false, username: body.username ?? "", solved: solved,
                       accepted: accepted, complete: body.complete ?? false, error: body.error)
    }

    /// One entry per problem per day, at that day's first accept, skipping problem-days already logged.
    public static func plan(accepted: [Accepted], logged: [Logged], now: Date, calendar: Calendar = .current) -> [Action] {
        func key(_ slug: String, _ date: Date) -> String { "\(slug)|\(calendar.startOfDay(for: date).timeIntervalSince1970)" }
        let have = Set(logged.compactMap { e in e.slug.map { key($0, e.date) } })
        var firsts: [String: Accepted] = [:]
        for a in accepted where a.date <= now.addingTimeInterval(-settle) {
            let k = key(a.slug, a.date)
            guard !have.contains(k) else { continue }
            if let f = firsts[k], f.date <= a.date { continue }
            firsts[k] = a
        }
        let missing = firsts.values.sorted { $0.date < $1.date }
        let byDay = Dictionary(grouping: missing) { calendar.startOfDay(for: $0.date) }
        let unmatched = Dictionary(grouping: logged.filter { $0.slug == nil && $0.fromLeetCode }) { calendar.startOfDay(for: $0.date) }
        return missing.map { a in
            let day = calendar.startOfDay(for: a.date)
            if byDay[day]?.count == 1, let typed = unmatched[day], typed.count == 1 { return .repair(id: typed[0].id, a) }
            return .add(a)
        }
    }
}
