import Foundation

/// Morning recall cues from yesterday's study only, grouped by subject.
/// The longest blocks of the whole day put news and spreadsheets in front of
/// the user (10/14), and window titles make poor cues ("Category: Admin"), so
/// a group shows its category, the course codes seen in it and cleaned topics.
public enum StudyRecall {
    public struct Block: Equatable {
        public var start: Date
        public var end: Date
        public var screenCategory: String?
        public var trackedCategory: String?
        public var title: String
        public var bullets: [String]
        public var windowTitles: [String]

        public init(start: Date, end: Date, screenCategory: String?, trackedCategory: String?,
                    title: String, bullets: [String] = [], windowTitles: [String] = []) {
            self.start = start
            self.end = end
            self.screenCategory = screenCategory
            self.trackedCategory = trackedCategory
            self.title = title
            self.bullets = bullets
            self.windowTitles = windowTitles
        }

        public var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    public struct Group: Equatable {
        public var category: String
        public var courses: [String]
        public var minutes: Double
        public var topics: [String]
        /// Indices into the blocks passed to `groups`, in time order.
        public var blocks: [Int]

        public var label: String { courses.isEmpty ? category : courses.joined(separator: ", ") }
    }

    /// Tracked as focus (or Class) and not something the screen calls life
    /// time, like news read during a Math block. Untracked time counts only if
    /// the screen saw focus work.
    public static func isStudy(_ b: Block, focus: Set<String>) -> Bool {
        if let s = b.screenCategory, !focus.contains(s), s != "Reading" { return false }
        if let t = b.trackedCategory { return focus.contains(t) || t == "Class" }
        return b.screenCategory.map(focus.contains) ?? false
    }

    /// Study groups, most minutes first.
    public static func groups(_ blocks: [Block], focus: Set<String>, coursePrefixes: [String: String] = [:],
                              maxGroups: Int = 4, maxTopics: Int = 4) -> [Group] {
        var byCategory: [String: [Int]] = [:]
        var order: [String] = []
        for (i, b) in blocks.enumerated() where isStudy(b, focus: focus) {
            let codes = courseCodes(in: text(of: b), prefixes: coursePrefixes)
            let category = category(of: b, codes: codes, focus: focus)
            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(i)
        }
        let all = order.map { category -> Group in
            let members = byCategory[category]!.sorted { blocks[$0].start < blocks[$1].start }
            var codeMinutes: [String: Double] = [:]
            for i in members {
                for c in courseCodes(in: text(of: blocks[i]), prefixes: coursePrefixes) {
                    codeMinutes[c, default: 0] += max(blocks[i].minutes, 0.1)
                }
            }
            let courses = codeMinutes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(2).map(\.key)
            return Group(category: category, courses: courses,
                         minutes: members.reduce(0) { $0 + blocks[$1].minutes },
                         topics: topics(members.map { blocks[$0] }, category: category, max: maxTopics),
                         blocks: members)
        }
        return Array(all.filter { $0.minutes >= 3 }.sorted { $0.minutes > $1.minutes }.prefix(maxGroups))
    }

    private static func text(of b: Block) -> String {
        ([b.title] + b.windowTitles + b.bullets).joined(separator: "\n")
    }

    private static func category(of b: Block, codes: [String], focus: Set<String>) -> String {
        if let t = b.trackedCategory, focus.contains(t), t != "HW" { return t }
        if let c = codes.lazy.compactMap(courseCategory).first { return c }
        if let s = b.screenCategory, focus.contains(s) { return s }
        return b.trackedCategory ?? b.screenCategory ?? "Study"
    }

    // MARK: Courses

    static let subjects: Set<String> = [
        "MATH", "CPSC", "CS", "ECON", "STAT", "SDS", "PHYS", "CHEM", "AMTH", "EENG", "ENAS", "MENG",
        "PSYC", "PHIL", "LING", "BIOL", "MCDB", "HIST", "ENGL", "PLSC", "GLBL", "ASTR", "EECS",
    ]

    private static let lettered = try! NSRegularExpression(pattern: #"\b([A-Za-z]{2,4}) ?-?(\d{3,4})\b"#)
    private static let bare = try! NSRegularExpression(pattern: #"(?<![A-Za-z])(?<![A-Za-z] )(?<![A-Za-z]-)\b(\d{3,4})\b"#)

    /// "MATH 2440", "math 244", "cpsc3231-midterm…" → "MATH 244", "CPSC 3231".
    /// A bare number becomes a course only through the calendar's prefixes
    /// ("3231 Study Guides" + a "CPSC 3231" class event).
    public static func courseCodes(in text: String, prefixes: [String: String] = [:]) -> [String] {
        var found: [String] = []
        func add(_ letters: String, _ number: String) {
            let n = number.count == 4 && number.hasSuffix("0") ? String(number.prefix(3)) : number
            let code = "\(letters) \(n)"
            if !found.contains(code) { found.append(code) }
        }
        let ns = text as NSString
        for m in lettered.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let letters = ns.substring(with: m.range(at: 1)).uppercased()
            guard subjects.contains(letters) || prefixes.values.contains(letters) else { continue }
            add(letters, ns.substring(with: m.range(at: 2)))
        }
        guard !prefixes.isEmpty else { return found }
        for m in bare.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: m.range(at: 1))
            if let letters = prefixes[number] { add(letters, number) }
        }
        return found
    }

    public static func courseCategory(_ code: String) -> String? {
        if code.hasPrefix("MATH ") { return "Math" }
        if code.hasPrefix("CPSC ") || code.hasPrefix("CS ") { return "SWE" }
        return nil
    }

    // MARK: Topics

    private static let filler: Set<String> = [
        "midterm", "midterms", "final", "finals", "exam", "exams", "review", "reviews", "reviewing", "prep",
        "preparation", "topics", "topic", "plan", "planning", "study", "studying", "notes", "note", "guide",
        "guides", "quick", "reference", "cheat", "sheet", "logistics", "etc", "session", "resume", "help",
    ]
    private static let generic: Set<String> = [
        "reading", "entertainment", "blocked", "untitled", "new tab", "chatgpt", "claude", "codex", "threads",
        "unknown", "focus",
    ]
    private static let edgeWords: Set<String> = ["and", "&", "of", "for", "the", "a", "an", "on", "to", "with", "-", "—"]

    /// A notes or window title as a topic: no app prefix, course code,
    /// category name or exam filler. nil when nothing specific is left.
    public static func topic(fromTitle raw: String, categories: Set<String> = []) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("category:") || generic.contains(t.lowercased()) { return nil }
        for p in ["ChatGPT: ", "Claude: ", "Codex: "] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) }
        t = t.replacingOccurrences(of: #"(?i)\b[A-Za-z]{2,4} ?-?\d{3,4}\b"#, with: " ", options: .regularExpression)
        let lowerCategories = Set(categories.map { $0.lowercased() })
        var words = t.split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { w in
                let l = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
                return !filler.contains(l) && !lowerCategories.contains(l) && l.rangeOfCharacter(from: .decimalDigits) == nil
            }
        while let f = words.first, edgeWords.contains(f.lowercased()) { words.removeFirst() }
        while let l = words.last, edgeWords.contains(l.lowercased()) { words.removeLast() }
        let result = words.joined(separator: " ")
        guard result.filter(\.isLetter).count >= 4 else { return nil }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    private static let definedTerm = try! NSRegularExpression(
        pattern: #"^(A\s+|An\s+|The\s+)?([A-Za-z][A-Za-z\- ]{2,28}?)\s+(?:is|are|means)\s+(?:a|an|the|when|if|how|that)\b"#)

    /// "(a) A chain is a subset…" → "Chain"; "Base case: substitute…" → "Base case".
    static func terms(inBullet raw: String) -> [String] {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t"))
            .replacingOccurrences(of: #"^\(\w{1,3}\)\s*"#, with: "", options: .regularExpression)
        var out: [String] = []
        let ns = line as NSString
        // Without an article, one word is usually not a term ("Today is the next day").
        if let m = definedTerm.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            let term = ns.substring(with: m.range(at: 2))
            if m.range(at: 1).location != NSNotFound || term.contains(" ") { out.append(term) }
        }
        if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 32 {
            let head = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let words = head.split(separator: " ")
            if (1...4).contains(words.count), head.rangeOfCharacter(from: .decimalDigits) == nil,
               head.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }),
               !["note", "example", "key distinction", "projects", "recents", "for example", "answer", "question"]
                .contains(head.lowercased()) {
                out.append(head)
            }
        }
        return out.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .filter { t in
                let l = t.lowercased()
                return l.filter(\.isLetter).count >= 4 && !filler.contains(l) && !l.hasPrefix("problem")
            }
    }

    /// Titles first (by minutes), then terms the notes define; no repeats.
    static func topics(_ blocks: [Block], category: String, max: Int) -> [String] {
        var minutesByTopic: [String: (topic: String, minutes: Double, first: Int)] = [:]
        for (i, b) in blocks.enumerated() {
            guard let t = topic(fromTitle: b.title, categories: [category, "Math", "SWE", "AI", "HW", "Quant"]) else { continue }
            let key = t.lowercased()
            let prior = minutesByTopic[key]
            minutesByTopic[key] = (prior?.topic ?? t, (prior?.minutes ?? 0) + b.minutes, prior?.first ?? i)
        }
        var out = minutesByTopic.values.sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.first < $1.first }
            .map(\.topic)
        var termCounts: [String: (term: String, count: Int, first: Int)] = [:]
        var n = 0
        for b in blocks {
            for line in b.bullets {
                for term in terms(inBullet: line) {
                    let key = term.lowercased()
                    termCounts[key] = (term, (termCounts[key]?.count ?? 0) + 1, termCounts[key]?.first ?? n)
                    n += 1
                }
            }
        }
        for t in termCounts.values.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first })
        where !out.contains(where: { $0.lowercased() == t.term.lowercased() }) {
            out.append(t.term)
        }
        return Array(out.prefix(max))
    }

    /// A notes title fit to show: the on-device writer sometimes echoes its
    /// prompt ("Category: Admin").
    public static func displayTitle(_ title: String, fallback: String) -> String {
        title.lowercased().hasPrefix("category:") || title.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : title
    }
}
