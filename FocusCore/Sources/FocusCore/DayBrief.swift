import Foundation

/// What Focus has to say about a day, written by the Mac (which has the
/// screen, the calendar and the AI's notes) for the phone through the iCloud
/// key-value store. Small on purpose: KVS holds 1 MB in all.
public struct DayBrief: Codable, Equatable, Sendable {
    public struct Fix: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var start: Date
        public var end: Date
        public var text: String
        /// The category one tap applies.
        public var suggestion: String?
        /// Reaches into the block the timer is running.
        public var running: Bool

        public init(id: String, start: Date, end: Date, text: String, suggestion: String?, running: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.suggestion = suggestion
            self.running = running
        }
    }

    public struct Block: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var category: String?
        public var title: String
        /// What the screen showed, in a few words.
        public var line: String?

        public init(start: Date, end: Date, category: String?, title: String, line: String?) {
            self.start = start
            self.end = end
            self.category = category
            self.title = title
            self.line = line
        }
    }

    public struct Course: Codable, Equatable, Sendable {
        public var code: String
        public var minutes: Double
        public var topics: [String]
        public var shaky: [String]

        public init(code: String, minutes: Double, topics: [String], shaky: [String]) {
            self.code = code
            self.minutes = minutes
            self.topics = topics
            self.shaky = shaky
        }
    }

    public var day: String
    public var written: Date
    public var headline: String?
    /// When the headline was written, if before the day ended.
    public var headlineAsOf: Date?
    public var fixes: [Fix]
    public var blocks: [Block]
    public var courses: [Course]
    public var noticed: [String]

    public init(day: String, written: Date, headline: String?, headlineAsOf: Date?, fixes: [Fix], blocks: [Block],
                courses: [Course], noticed: [String]) {
        self.day = day
        self.written = written
        self.headline = headline
        self.headlineAsOf = headlineAsOf
        self.fixes = fixes
        self.blocks = blocks
        self.courses = courses
        self.noticed = noticed
    }

    public static func make(day: Date, story: DayStory.Story, written: Date) -> DayBrief {
        let fixes = story.fixes.prefix(8).map { f in
            Fix(id: f.id, start: f.start, end: f.end, text: text(for: f), suggestion: f.suggestion, running: f.running)
        }
        let blocks = story.blocks.suffix(40).map { b in
            Block(start: b.start, end: b.end, category: b.category, title: b.title,
                  line: b.moments.first.map { trim($0.text, 90) })
        }
        let courses = story.courses.prefix(6).map { c in
            Course(code: c.code, minutes: c.minutes, topics: c.topics.prefix(6).map { trim($0, 80) },
                   shaky: c.shaky.prefix(4).map { trim($0, 100) })
        }
        return DayBrief(day: dayKey(day), written: written, headline: story.headline.map { trim($0, 400) },
                        headlineAsOf: story.headlineAsOf, fixes: Array(fixes), blocks: Array(blocks),
                        courses: Array(courses), noticed: story.noticed.prefix(4).map { trim($0, 200) })
    }

    /// Same wording as the Day page's fix rows.
    public static func text(for f: DayStory.Fix) -> String {
        let range = "\(clock(f.start))–\(clock(f.end))"
        switch f.kind {
        case .calendar(let event):
            return "Tracked as \(f.tracked ?? "something else") during \(event), \(range)."
        case .untracked(let seen):
            return seen.map { "Nothing logged \(range). The screen showed \($0)." } ?? "Nothing logged \(range)."
        case .screenDiffers(let seen):
            return "The screen showed \(seen) for \(durationText(minutes: f.minutes)) while \(f.tracked ?? "something else") was tracked."
        }
    }

    public static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private static func trim(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: - iCloud key-value store

    public static let key = "focusDayBriefs"

    /// Up to the last three days, by `dayKey`.
    public static func readAll(from kvs: NSUbiquitousKeyValueStore = .default) -> [String: DayBrief] {
        guard let data = kvs.data(forKey: key) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: DayBrief].self, from: data)) ?? [:]
    }

    public static func read(_ day: Date, from kvs: NSUbiquitousKeyValueStore = .default) -> DayBrief? {
        readAll(from: kvs)[dayKey(day)]
    }

    /// Writes only when the content changed (KVS is rate-limited).
    @discardableResult
    public func publish(to kvs: NSUbiquitousKeyValueStore = .default) -> Bool {
        var all = Self.readAll(from: kvs)
        if var old = all[day] {
            old.written = written
            if old == self { return false }
        }
        all[day] = self
        for k in all.keys.sorted().dropLast(3) { all[k] = nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(all) else { return false }
        kvs.set(data, forKey: Self.key)
        kvs.synchronize()
        return true
    }
}
