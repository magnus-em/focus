import Foundation

/// Which course a study observation, or a stretch of study, belongs to. The
/// vision model names a course only with on-screen proof (4 of 54
/// observations on 10/15), so the rest is filled in deterministically,
/// strongest evidence first: the model's course, a course code in the window
/// title or address (OCR-garbled letters allowed: "Plan MAIH 244 miaterm
/// prep"), the calendar class on at the time, the same window elsewhere that
/// day, an observation of the same subject within 20 minutes, and last the
/// category when only one course has it and that course was seen that day.
/// Neighbours only lend courses they got from their own evidence, so a
/// course never creeps across an afternoon one observation at a time.
public enum CoachCourse {
    public struct Course: Equatable, Sendable {
        public var code: String
        public var category: String?

        public init(_ code: String, category: String?) {
            self.code = code
            self.category = category
        }
    }

    public enum Basis: String, Codable, Sendable {
        case model, title, calendar, window, neighbour, category

        /// Evidence about this observation itself, not borrowed from others.
        public var isDirect: Bool { self == .model || self == .title || self == .calendar }
    }

    public struct Attribution: Equatable, Sendable {
        public var course: String
        public var basis: Basis

        public init(course: String, basis: Basis) {
            self.course = course
            self.basis = basis
        }
    }

    /// A calendar class or exam ("MATH 244 Midterm 1", "3231 Exam 1").
    public struct ClassEvent: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var title: String

        public init(start: Date, end: Date, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    public struct Context: Sendable {
        public var courses: [Course]
        public var coursePrefixes: [String: String]
        public var classes: [ClassEvent]

        /// The semester's courses: the known ones plus any the calendar names.
        public init(coursePrefixes: [String: String] = [:], classes: [ClassEvent] = [], known: [Course] = CoachCourse.known) {
            var courses = known
            for (number, letters) in coursePrefixes.sorted(by: { $0.key < $1.key }) {
                guard CoachCourse.canonical(letters: letters.uppercased(), number: number, in: courses) == nil else { continue }
                let code = "\(letters.uppercased()) \(number)"
                courses.append(Course(code, category: StudyRecall.courseCategory(code)))
            }
            self.courses = courses
            self.coursePrefixes = coursePrefixes
            self.classes = classes
        }
    }

    /// Fall 2026, as the coach prompts list them.
    public static let known: [Course] = [
        Course("CPSC 3231", category: "SWE"), Course("MATH 244", category: "Math"), Course("CPSC 1710", category: "AI"),
    ]

    static let studyCategories: Set<String> = ["Math", "SWE", "HW", "AI", "Quant", "Class", "Reading"]
    private static let interviewPrep = ["leetcode", "neetcode", "hackerrank", "codeforces"]
    private static let window = TimeInterval(20 * 60)

    // MARK: Lookups

    /// One observation's course, judged with the rest of its day around it.
    public static func course(for record: CoachEpisode.Record, neighbours: [CoachEpisode.Record], context: Context) -> String? {
        let all = neighbours.contains { $0.source.id == record.source.id } ? neighbours : neighbours + [record]
        return attribute(all, context: context)[record.source.id]?.course
    }

    /// The same, computed once for many lookups over the same records.
    public static func resolver(_ records: [CoachEpisode.Record], context: Context) -> (CoachEpisode.Record) -> String? {
        let map = attribute(records, context: context)
        return { map[$0.source.id]?.course }
    }

    /// The subject an observation counts toward, or nil for anything that
    /// isn't study (admin, life categories): the same rule `enforceDepth` uses.
    public static func studyCategory(_ r: CoachEpisode.Record) -> String? {
        guard r.understanding.activity != "admin", let c = r.source.category ?? r.source.trackedCategory,
              studyCategories.contains(c) else { return nil }
        return c
    }

    public static func attribute(_ records: [CoachEpisode.Record], context: Context) -> [UUID: Attribution] {
        let study = records.filter { studyCategory($0) != nil }.sorted { $0.source.at < $1.source.at }
        var out: [UUID: Attribution] = [:]
        for r in study {
            if let a = direct(r, context: context) { out[r.source.id] = a }
        }
        let anchors = study.filter { out[$0.source.id] != nil }
        var byWindow: [String: [String: Int]] = [:]
        for r in anchors {
            guard let key = windowKey(r) else { continue }
            byWindow[key, default: [:]][out[r.source.id]!.course, default: 0] += 1
        }
        let seen = Set(anchors.map { out[$0.source.id]!.course })
        for r in study where out[r.source.id] == nil && !isInterviewPrep(r) {
            if let key = windowKey(r), let votes = byWindow[key], let best = majority(votes) {
                out[r.source.id] = Attribution(course: best, basis: .window)
                continue
            }
            let category = studyCategory(r)
            let near = anchors.filter { studyCategory($0) == category }
                .map { ($0, gap($0.source.at, $0.source.end, r.source.at, r.source.end)) }
                .filter { $0.1 <= window }
                .min { $0.1 < $1.1 }
            if let near {
                out[r.source.id] = Attribution(course: out[near.0.source.id]!.course, basis: .neighbour)
            } else if let only = onlyCourse(for: category, context: context), seen.contains(only) {
                out[r.source.id] = Attribution(course: only, basis: .category)
            }
        }
        return out
    }

    /// A stretch of time: the course its observations add up to (by
    /// minutes), else a code in its window titles, a calendar class over it,
    /// or its category's only course when that course was seen that day.
    public static func stretch(start: Date, end: Date, category: String?, titles: [String] = [],
                               records: [CoachEpisode.Record], context: Context) -> Attribution? {
        let attributions = attribute(records, context: context)
        var minutes: [String: Double] = [:]
        var basis: [String: Basis] = [:]
        for r in records where r.source.at < end && r.source.end > start {
            guard let a = attributions[r.source.id] else { continue }
            let overlap = min(end, r.source.end).timeIntervalSince(max(start, r.source.at))
            minutes[a.course, default: 0] += max(overlap, 15)
            if basis[a.course].map({ rank($0) > rank(a.basis) }) ?? true { basis[a.course] = a.basis }
        }
        if let best = majority(minutes) { return Attribution(course: best, basis: basis[best]!) }
        if let code = titles.lazy.compactMap({ codes(in: $0, context: context).first }).first {
            return Attribution(course: code, basis: .title)
        }
        let classes = context.classes.filter { $0.start < end && $0.end > start }
            .sorted { min(end, $0.end).timeIntervalSince(max(start, $0.start)) > min(end, $1.end).timeIntervalSince(max(start, $1.start)) }
        for c in classes {
            guard let code = codes(in: c.title, context: context).first else { continue }
            if category == "Class" || category == nil || courseCategory(code, context: context) == category {
                return Attribution(course: code, basis: .calendar)
            }
        }
        let seen = Set(attributions.values.filter(\.basis.isDirect).map(\.course))
        if let only = onlyCourse(for: category, context: context), seen.contains(only) {
            return Attribution(course: only, basis: .category)
        }
        return nil
    }

    // MARK: Evidence

    private static func direct(_ r: CoachEpisode.Record, context: Context) -> Attribution? {
        if let raw = r.understanding.course?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return Attribution(course: codes(in: raw, context: context).first ?? raw, basis: .model)
        }
        let url = r.source.url.flatMap { URL(string: $0)?.path.removingPercentEncoding }
        if let code = ([r.source.title] + (url.map { [$0] } ?? [])).lazy
            .compactMap({ codes(in: $0, context: context).first }).first {
            return Attribution(course: code, basis: .title)
        }
        let category = studyCategory(r)
        for c in context.classes where c.start <= r.source.at && c.end > r.source.at {
            guard let code = codes(in: c.title, context: context).first else { continue }
            if category == "Class" || r.source.trackedCategory == "Class" || courseCategory(code, context: context) == category {
                return Attribution(course: code, basis: .calendar)
            }
        }
        return nil
    }

    private static let lettered = try! NSRegularExpression(pattern: #"(?<![A-Za-z])([A-Za-z]{2,4}) ?-?(\d{3,4})(?!\d)"#)
    private static let bare = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?<![A-Za-z] )(\d{3,4})(?![0-9])"#)

    /// Course codes in a title, canonical to the semester's courses:
    /// "math 2440", "MAIH 244", "cpsc3231-midterm-cheat-sheet.pdf", "CPSC 323"
    /// (the old number), and a bare "3231" the calendar or the known
    /// courses vouch for. Unknown subjects pass through as written.
    public static func codes(in text: String, context: Context) -> [String] {
        var found: [String] = []
        func add(_ code: String) { if !found.contains(code) { found.append(code) } }
        let ns = text as NSString
        for m in lettered.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let letters = ns.substring(with: m.range(at: 1)).uppercased()
            let number = ns.substring(with: m.range(at: 2))
            if let code = canonical(letters: letters, number: number, in: context.courses) {
                add(code)
            } else if StudyRecall.subjects.contains(letters) {
                add("\(letters) \(number)")
            }
        }
        for m in bare.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let number = ns.substring(with: m.range(at: 1))
            if let letters = context.coursePrefixes[number] {
                add(canonical(letters: letters.uppercased(), number: number, in: context.courses) ?? "\(letters.uppercased()) \(number)")
            } else if number.count == 4, let course = context.courses.first(where: { $0.code.hasSuffix(" " + number) }) {
                add(course.code)
            }
        }
        return found
    }

    static func canonical(letters: String, number: String, in courses: [Course]) -> String? {
        for course in courses {
            let parts = course.code.split(separator: " ")
            guard parts.count == 2 else { continue }
            let l = String(parts[0]), n = String(parts[1])
            let zero = n == number || (number.count == 4 && n.count == 3 && number == n + "0")
                || (n.count == 4 && number.count == 3 && n == number + "0")
            if l == letters, zero || (n.count == 4 && number.count == 3 && n.hasPrefix(number)) { return course.code }
            if zero, letters.count >= 3, letters.count == l.count,
               zip(letters, l).filter({ $0 != $1 }).count == 1 { return course.code }
        }
        return nil
    }

    private static func courseCategory(_ code: String, context: Context) -> String? {
        context.courses.first { $0.code == code }?.category ?? StudyRecall.courseCategory(code)
    }

    private static func onlyCourse(for category: String?, context: Context) -> String? {
        guard let category else { return nil }
        let matches = context.courses.filter { $0.category == category }
        return matches.count == 1 ? matches[0].code : nil
    }

    private static func windowKey(_ r: CoachEpisode.Record) -> String? {
        let title = r.source.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard title.count >= 8, title != r.source.app.lowercased(), !["new chat", "new tab"].contains(title) else { return nil }
        return r.source.bundle + "|" + title
    }

    private static func isInterviewPrep(_ r: CoachEpisode.Record) -> Bool {
        let text = (r.source.title + " " + (r.source.url ?? "") + " " + r.understanding.topic).lowercased()
        return interviewPrep.contains { text.contains($0) }
    }

    private static func gap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
        max(0, max(a0, b0).timeIntervalSince(min(a1, b1)))
    }

    private static func majority<N: Comparable>(_ votes: [String: N]) -> String? {
        votes.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    private static func rank(_ b: Basis) -> Int {
        [.model, .title, .calendar, .window, .neighbour, .category].firstIndex(of: b)!
    }
}
