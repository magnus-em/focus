import Foundation
import FocusCore

enum LCList: Int, CaseIterable, Identifiable {
    case blind75 = 1, neetcode150 = 2, neetcode250 = 4, grind75 = 8, grind169 = 16

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .blind75:     return "Blind 75"
        case .neetcode150: return "NeetCode 150"
        case .neetcode250: return "NeetCode 250"
        case .grind75:     return "Grind 75"
        case .grind169:    return "Grind 169"
        }
    }
}

struct LCProblem: Identifiable, Hashable {
    let number: Int
    let title: String
    let slug: String
    let difficulty: ProblemDifficulty
    let acceptance: Double
    let paidOnly: Bool
    let tags: [String]
    /// Single primary pattern from `ProblemDomain.swe.categories` — one per problem so
    /// pattern stats aren't diluted by incidental tags like "array".
    let category: String
    let listMask: Int

    var id: String { slug }
    var url: String { "https://leetcode.com/problems/\(slug)/" }
    var categories: [String] { category.isEmpty ? [] : [category] }
    func isIn(_ list: LCList) -> Bool { listMask & list.rawValue != 0 }
    var isCurated: Bool { listMask != 0 }
}

/// All LeetCode algorithm problems. Ships as `Resources/leetcode.json` (generated from
/// LeetCode's GraphQL API + NeetCode pattern labels + Grind lists) and can be refreshed
/// from LeetCode at runtime into Application Support.
@MainActor
final class LeetCodeCatalog: ObservableObject {
    static let shared = LeetCodeCatalog()

    @Published private(set) var problems: [LCProblem] = []
    @Published private(set) var generated = ""
    @Published private(set) var isRefreshing = false
    @Published var refreshMessage: String?

    private(set) var bySlug: [String: LCProblem] = [:]
    private var byTitle: [String: LCProblem] = [:]
    private var searchKeys: [String: String] = [:]

    private static let cacheURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/leetcode-catalog.json")

    private init() { load() }

    // MARK: - Lookup

    func problem(slug: String) -> LCProblem? { bySlug[slug] }

    func problem(matching entry: ProblemEntry) -> LCProblem? {
        guard entry.domain == .swe else { return nil }
        if let slug = Self.slug(fromURL: entry.url), let p = bySlug[slug] { return p }
        return byTitle[Self.normalize(entry.title)]
    }

    /// Number ("146"), title words ("lru cache"), or both ("146 lru").
    func search(_ query: String, in pool: [LCProblem]? = nil) -> [LCProblem] {
        let q = Self.normalize(query)
        let source = pool ?? problems
        guard !q.isEmpty else { return source }
        if let n = Int(q) {
            let exact = source.filter { $0.number == n }
            let prefix = source.filter { $0.number != n && String($0.number).hasPrefix(q) }
            return exact + prefix
        }
        let terms = q.split(separator: " ").map(String.init)
        let hits = source.filter { p in
            let key = searchKeys[p.slug] ?? ""
            return terms.allSatisfy { key.contains($0) }
        }
        return hits.sorted { a, b in
            let ap = Self.normalize(a.title).hasPrefix(q), bp = Self.normalize(b.title).hasPrefix(q)
            return ap != bp ? ap : a.number < b.number
        }
    }

    // MARK: - Load

    private func load() {
        var docs: [[String: Any]] = []
        let resourceBundle = Bundle.focusResources
        if let url = resourceBundle?.url(forResource: "leetcode", withExtension: "json")
            ?? Bundle.main.url(forResource: "leetcode", withExtension: "json"),
           let doc = Self.readDoc(url) {
            docs.append(doc)
        }
        if let doc = Self.readDoc(Self.cacheURL) { docs.append(doc) }
        // A newer app build can ship a fresher catalog than an old cached refresh.
        guard let best = docs.max(by: { ($0["generated"] as? String ?? "") < ($1["generated"] as? String ?? "") })
        else { return }
        apply(Self.parse(best), generated: best["generated"] as? String ?? "")
    }

    private func apply(_ list: [LCProblem], generated: String) {
        problems = list
        self.generated = generated
        bySlug = Dictionary(list.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        byTitle = Dictionary(list.map { (Self.normalize($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        searchKeys = Dictionary(list.map { ($0.slug, "\($0.number) " + Self.normalize($0.title)) },
                                uniquingKeysWith: { a, _ in a })
    }

    private static func readDoc(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func parse(_ doc: [String: Any]) -> [LCProblem] {
        let cats = doc["categories"] as? [String] ?? ProblemDomain.swe.categories
        let tags = doc["tags"] as? [String] ?? []
        let rows = doc["problems"] as? [[Any]] ?? []
        let difficulties: [ProblemDifficulty] = [.easy, .medium, .hard]
        return rows.compactMap { r in
            guard r.count >= 9,
                  let n = r[0] as? Int, let title = r[1] as? String, let slug = r[2] as? String,
                  let d = r[3] as? Int, d >= 0, d < 3 else { return nil }
            let tagSlugs = (r[6] as? [Int] ?? []).compactMap { $0 < tags.count ? tags[$0] : nil }
            let pattern = r[7] as? Int ?? -1
            let category = pattern >= 0 && pattern < cats.count
                ? cats[pattern]
                : primaryCategory(tags: tagSlugs, title: title)
            return LCProblem(number: n, title: title, slug: slug, difficulty: difficulties[d],
                             acceptance: (r[4] as? NSNumber)?.doubleValue ?? 0,
                             paidOnly: (r[5] as? Int ?? 0) != 0,
                             tags: tagSlugs, category: category,
                             listMask: r[8] as? Int ?? 0)
        }
    }

    // MARK: - Tag → pattern

    // Ordered most-specific first; the first rule that matches wins.
    private static let rules: [(String, Set<String>)] = [
        ("Tries", ["trie"]),
        ("Heap", ["heap-priority-queue", "heap"]),
        ("Backtracking", ["backtracking"]),
        ("Dynamic Programming", ["dynamic-programming", "memoization", "dp-on-trees", "knapsack-problem",
                                 "0-1-knapsack", "complete-knapsack", "longest-increasing-subsequence",
                                 "longest-common-subsequence"]),
        ("Linked List", ["linked-list", "doubly-linked-list"]),
        ("Trees", ["tree", "binary-tree", "binary-search-tree", "lowest-common-ancestor"]),
        ("Graphs", ["graph", "union-find", "topological-sort", "shortest-path", "dijkstra",
                    "minimum-spanning-tree", "bipartite-graph", "directed-acyclic-graph",
                    "strongly-connected-component", "eulerian-circuit", "breadth-first-search",
                    "depth-first-search"]),
        ("Sliding Window", ["sliding-window", "monotonic-queue"]),
        ("Two Pointers", ["two-pointers"]),
        ("Binary Search", ["binary-search"]),
        ("Stack", ["stack", "monotonic-stack"]),
        ("Bit Manipulation", ["bit-manipulation", "bitmask"]),
        ("Greedy", ["greedy"]),
        ("Math & Geometry", ["math", "geometry", "number-theory", "combinatorics", "matrix"]),
        ("Arrays & Hashing", ["array", "hash-table", "string", "sorting", "prefix-sum", "counting",
                              "hash-function"]),
    ]

    static func primaryCategory(tags: [String], title: String) -> String {
        let set = Set(tags)
        if title.lowercased().contains("interval") || set.contains("sweep-line") { return "Intervals" }
        let treeish = !set.isDisjoint(with: ["tree", "binary-tree", "binary-search-tree"])
        for (cat, keys) in rules {
            var hit = set.intersection(keys)
            // Tree traversals are tagged BFS/DFS too; don't let that make them "Graphs".
            if cat == "Graphs" && treeish { hit.subtract(["breadth-first-search", "depth-first-search"]) }
            if !hit.isEmpty { return cat }
        }
        return "Arrays & Hashing"
    }

    // MARK: - Refresh from LeetCode

    func refreshFromLeetCode() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshMessage = nil
        defer { isRefreshing = false }
        do {
            var raw: [[String: Any]] = []
            var skip = 0
            var total = Int.max
            while skip < total {
                let (page, t) = try await Self.fetchPage(skip: skip)
                total = t
                raw += page
                skip += 100
                if page.isEmpty { break }
            }
            let fresh = raw.compactMap(freshProblem(from:)).sorted { $0.number < $1.number }
            guard fresh.count > problems.count / 2 else {
                refreshMessage = "LeetCode returned too few problems — kept the current list."
                return
            }
            let added = fresh.count - problems.count
            let stamp = ISO8601DateFormatter().string(from: Date())
            try writeCache(fresh, generated: stamp)
            apply(fresh, generated: stamp)
            refreshMessage = added > 0 ? "Added \(added) new problems." : "Already up to date."
        } catch {
            refreshMessage = "Couldn't reach LeetCode: \(error.localizedDescription)"
        }
    }

    private func freshProblem(from q: [String: Any]) -> LCProblem? {
        guard q["categoryTitle"] as? String == "Algorithms",
              let slug = q["titleSlug"] as? String, let title = q["title"] as? String,
              let n = Int(q["frontendQuestionId"] as? String ?? "") else { return nil }
        let diff: ProblemDifficulty
        switch q["difficulty"] as? String {
        case "Easy": diff = .easy
        case "Hard": diff = .hard
        default:     diff = .medium
        }
        let tags = (q["topicTags"] as? [[String: Any]] ?? []).compactMap { $0["slug"] as? String }
        let existing = bySlug[slug]
        return LCProblem(number: n, title: title, slug: slug, difficulty: diff,
                         acceptance: ((q["acRate"] as? NSNumber)?.doubleValue ?? 0).rounded(toPlaces: 1),
                         paidOnly: q["paidOnly"] as? Bool ?? false, tags: tags,
                         category: existing?.category ?? Self.primaryCategory(tags: tags, title: title),
                         listMask: existing?.listMask ?? 0)
    }

    private static func fetchPage(skip: Int) async throws -> ([[String: Any]], Int) {
        var req = URLRequest(url: URL(string: "https://leetcode.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://leetcode.com/problemset/", forHTTPHeaderField: "Referer")
        let query = """
        query q($skip: Int, $limit: Int) { problemsetQuestionList: questionList(categorySlug: "", \
        limit: $limit, skip: $skip, filters: {}) { total: totalNum questions: data { acRate difficulty \
        frontendQuestionId: questionFrontendId paidOnly: isPaidOnly title titleSlug categoryTitle \
        topicTags { slug } } } }
        """
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["skip": skip, "limit": 100],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = (obj?["data"] as? [String: Any])?["problemsetQuestionList"] as? [String: Any]
        guard let list else { throw URLError(.cannotParseResponse) }
        return (list["questions"] as? [[String: Any]] ?? [], list["total"] as? Int ?? 0)
    }

    private func writeCache(_ list: [LCProblem], generated: String) throws {
        let cats = ProblemDomain.swe.categories
        let tags = Array(Set(list.flatMap(\.tags))).sorted()
        let tagIndex = Dictionary(uniqueKeysWithValues: tags.enumerated().map { ($1, $0) })
        let rows: [[Any]] = list.map { p in
            [p.number, p.title, p.slug, [ProblemDifficulty.easy, .medium, .hard].firstIndex(of: p.difficulty) ?? 1,
             p.acceptance, p.paidOnly ? 1 : 0, p.tags.compactMap { tagIndex[$0] },
             cats.firstIndex(of: p.category) ?? -1, p.listMask]
        }
        let doc: [String: Any] = ["version": 1, "generated": generated, "categories": cats,
                                  "tags": tags, "problems": rows]
        let data = try JSONSerialization.data(withJSONObject: doc)
        try FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Helpers

    static func slug(fromURL url: String) -> String? {
        guard let r = url.range(of: "leetcode.com/problems/") else { return nil }
        let slug = url[r.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return slug.isEmpty ? nil : slug.lowercased()
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10, Double(p))
        return (self * m).rounded() / m
    }
}
