import Foundation

/// One readable story per day, for the Dashboard's Day page, the popover's
/// recent stretches and the morning sheet. The coach's day record covers the
/// day up to when it was written; live observations cover the rest; tracked
/// sessions fill whatever neither saw. Consecutive study of the same course
/// becomes one block with its moments inside, and short side trips between
/// them become one quiet "interruptions" line instead of rows of their own.
/// Fixes come from plain rules over tracked time, the calendar and the
/// screen, never from the model.
public enum DayStory {
    public struct Tracked: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var label: String
        public var running: Bool

        public init(start: Date, end: Date, label: String, running: Bool = false) {
            self.start = start
            self.end = end
            self.label = label
            self.running = running
        }
    }

    public struct CalendarEvent: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var title: String

        public init(start: Date, end: Date, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    /// A smoothed stretch of what the on-device labeler saw.
    public struct Screen: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var category: String?
        public var uncertain: Bool

        public init(start: Date, end: Date, category: String?, uncertain: Bool = false) {
            self.start = start
            self.end = end
            self.category = category
            self.uncertain = uncertain
        }
    }

    /// On-device notes for a stretch, used only where the coach saw nothing.
    public struct Note: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var title: String

        public init(start: Date, end: Date, title: String) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    public struct Moment: Equatable, Sendable, Identifiable {
        public var start: Date
        public var end: Date
        public var text: String
        public var detail: String?
        /// The user's own questions, never prompts copied off the screen.
        public var asked: [String]
        public var activities: [String]
        public var category: String?

        public var id: Date { start }
        public var minutes: Double { end.timeIntervalSince(start) / 60 }

        public init(start: Date, end: Date, text: String, detail: String? = nil, asked: [String] = [],
                    activities: [String] = [], category: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.detail = detail
            self.asked = asked
            self.activities = activities
            self.category = category
        }
    }

    public struct Fix: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// Tracked as something other than Class during a calendar class or exam.
            case calendar(event: String)
            /// Nothing tracked; `seen` is the focus category the screen showed, if any.
            case untracked(seen: String?)
            /// The screen showed another category for a while.
            case screenDiffers(seen: String)
        }

        public var kind: Kind
        public var start: Date
        public var end: Date
        public var tracked: String?
        /// The category one click applies, if there is an obvious one.
        public var suggestion: String?
        public var running: Bool

        public var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
        public var minutes: Double { end.timeIntervalSince(start) / 60 }

        public init(kind: Kind, start: Date, end: Date, tracked: String?, suggestion: String?, running: Bool = false) {
            self.kind = kind
            self.start = start
            self.end = end
            self.tracked = tracked
            self.suggestion = suggestion
            self.running = running
        }
    }

    public struct Block: Equatable, Sendable, Identifiable {
        public var start: Date
        public var end: Date
        /// Tracked category, or what the screen/coach saw when nothing was tracked. nil = untracked.
        public var category: String?
        public var course: String?
        /// A calendar event this block sits in.
        public var event: String?
        public var study: Bool
        public var moments: [Moment]
        public var interruptions: [Moment]
        public var fixes: [Fix]
        public var running: Bool
        /// On-screen minutes of the moments, without the side trips.
        public var minutes: Double

        public var id: Date { start }
        public var title: String { event ?? course ?? category ?? "Untracked" }
        /// Sleep, breaks and short life stretches: shown as one line.
        public var quiet: Bool {
            guard fixes.isEmpty else { return false }
            if category == "Sleep" || category == "Break" { return true }
            return !study && end.timeIntervalSince(start) < 6 * 60
        }
    }

    public struct Course: Equatable, Sendable, Identifiable {
        public var code: String
        public var category: String
        public var minutes: Double
        public var topics: [String]
        public var shaky: [String]
        public var digest: String?
        /// Observation counts by activity (asking-ai, reading, solving…).
        public var activity: [String: Int]

        public var id: String { code }
        public var observations: Int { activity.values.reduce(0, +) }
        /// Solving, writing or coding: work done, not read.
        public var practiceShare: Double? {
            guard observations > 0 else { return nil }
            let practice = ["solving", "writing", "coding"].reduce(0) { $0 + (activity[$1] ?? 0) }
            return Double(practice) / Double(observations)
        }
    }

    public struct Story: Equatable, Sendable {
        public var headline: String?
        /// When the record was written before its day ended.
        public var headlineAsOf: Date?
        public var blocks: [Block]
        public var fixes: [Fix]
        public var courses: [Course]
        public var noticed: [String]
        public var questions: Int
        /// The day record or observations were available.
        public var hasCoach: Bool
    }

    public static let studyActivities: Set<String> = ["reading", "solving", "coding", "writing", "asking-ai", "watching"]

    // MARK: Build

    public static func build(day: Date, now: Date, tracked: [Tracked], record: CoachDay.Record?,
                             observations: [CoachEpisode.Record], events: [CalendarEvent] = [],
                             screen: [Screen] = [], notes: [Note] = [], focus: Set<String>,
                             coursePrefixes: [String: String] = [:],
                             course: (CoachEpisode.Record) -> String? = { $0.understanding.course },
                             asked: (CoachEpisode.Record) -> [String] = { $0.understanding.askedByUser },
                             calendar: Calendar = .current) -> Story {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = min(calendar.date(byAdding: .day, value: 1, to: dayStart)!, now)
        guard dayEnd > dayStart else {
            return Story(headline: nil, headlineAsOf: nil, blocks: [], fixes: [], courses: [], noticed: [], questions: 0,
                         hasCoach: false)
        }
        let tracked = tracked.compactMap { t -> Tracked? in
            var t = t
            t.start = max(t.start, dayStart)
            t.end = min(t.end, dayEnd)
            return t.end > t.start ? t : nil
        }.sorted { $0.start < $1.start }
        let fullEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let cutoff = record.map { min($0.generatedAt, dayEnd) } ?? dayStart
        let known = Set((record?.content.study ?? []).compactMap(\.course).flatMap { codes($0, prefixes: coursePrefixes) })

        var items: [Item] = []
        if let record {
            for e in record.content.timeline {
                guard var start = clock(e.start, on: dayStart, calendar: calendar),
                      var end = clock(e.end, on: dayStart, calendar: calendar) else { continue }
                if end <= start { end = fullEnd }
                start = max(start, dayStart)
                end = min(end, cutoff)
                guard end > start else { continue }
                let found = codes(e.what, prefixes: coursePrefixes).map { canonical($0, known: known) }
                items.append(Item(start: start, end: end, category: e.category, course: found.first,
                                  moment: Moment(start: start, end: end, text: e.what, category: e.category),
                                  evidence: true))
            }
        }
        for run in runs(observations.filter { $0.source.at >= cutoff && $0.source.at < dayEnd }, asked: asked) {
            let label = trackedLabel(tracked, at: run.start, end: run.end) ?? run.screen ?? run.records.first?.source.category
            let resolved = run.records.lazy.compactMap(course).first
                ?? codes(run.records.map { "\($0.source.title) \($0.understanding.topic)" }.joined(separator: "\n"),
                         prefixes: coursePrefixes).first
            let isAdmin = run.records.allSatisfy { $0.understanding.activity == "admin" }
            items.append(Item(start: run.start, end: run.end, category: label,
                              course: isAdmin ? nil : resolved.map { canonical($0, known: known) },
                              moment: run.moment, evidence: true))
        }
        let covered = items.map { ($0.start, $0.end) }
        for t in tracked {
            for piece in subtract((t.start, t.end), covered) where piece.1.timeIntervalSince(piece.0) >= 60 {
                for part in split(piece, at: events) {
                    let event = events.first { $0.start <= part.0 && part.1 <= $0.end && part.1 > $0.start }
                    let note = notes.filter { $0.end > part.0 && $0.start < part.1 }
                        .max { overlap(($0.start, $0.end), part) < overlap(($1.start, $1.end), part) }
                    items.append(Item(start: part.0, end: part.1, category: t.label, course: nil,
                                      moment: note.map { Moment(start: part.0, end: part.1, text: $0.title, category: t.label) },
                                      evidence: false, event: event?.title, running: t.running && part.1 >= t.end))
                }
            }
        }
        items.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        fillCourses(&items, focus: focus)

        let fixes = fixList(tracked: tracked, events: events, screen: screen, items: items, focus: focus,
                            dayStart: dayStart, dayEnd: dayEnd)
        var blocks = group(items, focus: focus)
        for (i, b) in blocks.enumerated() {
            blocks[i].fixes = fixes.filter { $0.start < b.end && $0.end > b.start && !isUntracked($0) }
        }
        for f in fixes where isUntracked(f) {
            blocks.append(Block(start: f.start, end: f.end, category: nil, course: nil, event: nil, study: false,
                                moments: [], interruptions: [], fixes: [f], running: false,
                                minutes: f.minutes))
        }
        blocks.sort { $0.start < $1.start }

        return Story(headline: record?.content.headline,
                     headlineAsOf: record.flatMap { $0.generatedAt < fullEnd ? $0.generatedAt : nil },
                     blocks: blocks, fixes: fixes,
                     courses: courses(blocks: blocks, record: record, observations: observations, course: course,
                                      known: known, prefixes: coursePrefixes, focus: focus),
                     noticed: record?.content.observations ?? [],
                     questions: record?.content.questions.count ?? 0,
                     hasCoach: record != nil || !observations.isEmpty)
    }

    // MARK: Items

    struct Item {
        var start: Date
        var end: Date
        var category: String?
        var course: String?
        var moment: Moment?
        var evidence: Bool
        var event: String? = nil
        var running = false
        var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    struct Run {
        var records: [CoachEpisode.Record]
        var start: Date
        var end: Date
        var screen: String?
        var moment: Moment
    }

    /// Consecutive observations of one subject less than 10 minutes apart. A
    /// subject is the same when the topic matches or the concepts overlap;
    /// admin observations only join other admin.
    static func runs(_ records: [CoachEpisode.Record], asked: (CoachEpisode.Record) -> [String]) -> [Run] {
        var groups: [[CoachEpisode.Record]] = []
        for r in records.sorted(by: { $0.source.at < $1.source.at }) {
            if let group = groups.last, let last = group.last, r.source.at.timeIntervalSince(last.source.end) < 600,
               group.contains(where: { sameSubject($0, r) }) {
                groups[groups.count - 1].append(r)
            } else {
                groups.append([r])
            }
        }
        return groups.map { g in
            let topics = ranked(g.map(\.understanding.topic))
            let concepts = ranked(g.flatMap(\.understanding.concepts))
            var questions: [String] = []
            for q in g.flatMap(asked) where !questions.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                questions.append(q)
            }
            let activities = ranked(g.map(\.understanding.activity))
            let start = g.first!.source.at
            let end = max(g.map(\.source.end).max()!, start.addingTimeInterval(60))
            let screen = ranked(g.compactMap(\.source.category)).first
            let detail = concepts.isEmpty ? nil : concepts.prefix(5).joined(separator: ", ")
            return Run(records: g, start: start, end: end, screen: screen,
                       moment: Moment(start: start, end: end, text: topics.first ?? "", detail: detail,
                                      asked: Array(questions.prefix(2)), activities: activities, category: screen))
        }
    }

    static func sameSubject(_ a: CoachEpisode.Record, _ b: CoachEpisode.Record) -> Bool {
        let ua = a.understanding, ub = b.understanding
        if (ua.activity == "admin") != (ub.activity == "admin") { return false }
        if ua.activity == "admin" { return true }
        if ua.topic.caseInsensitiveCompare(ub.topic) == .orderedSame { return true }
        if let ca = ua.course, let cb = ub.course, ca != cb { return false }
        let sa = Set(ua.concepts.map { $0.lowercased() }), sb = Set(ub.concepts.map { $0.lowercased() })
        return !sa.isDisjoint(with: sb)
    }

    /// Study items without a course take the course of the nearest study item
    /// in the same category, so "Math" stretches between MATH 244 ones read as MATH 244.
    static func fillCourses(_ items: inout [Item], focus: Set<String>) {
        for i in items.indices where items[i].course == nil && items[i].evidence {
            guard let c = items[i].category, focus.contains(c) else { continue }
            let candidates = items.indices.filter { items[$0].course != nil && items[$0].category == c }
            if let nearest = candidates.min(by: {
                abs(items[$0].start.timeIntervalSince(items[i].start)) < abs(items[$1].start.timeIntervalSince(items[i].start))
            }) {
                items[i].course = items[nearest].course
            }
        }
        for i in items.indices where items[i].course == nil && !items[i].evidence {
            guard let c = items[i].category, focus.contains(c) else { continue }
            let near = items.filter { $0.evidence && $0.category == c && $0.course != nil
                && abs($0.end.timeIntervalSince(items[i].start)) < 3600 }
            items[i].course = near.last?.course
        }
    }

    static func isStudyItem(_ item: Item, focus: Set<String>) -> Bool {
        guard let c = item.category else { return false }
        if let m = item.moment, m.activities.first == "admin" { return false }
        return focus.contains(c)
    }

    /// Items into blocks. Study items of one course less than 15 minutes apart
    /// share a block; anything short and non-study between two of them is a
    /// side trip of that block. More than 15 minutes of study tracked with
    /// nothing seen stays a block of its own (unless it's the running one);
    /// life time of one category merges whatever the evidence, and a calendar
    /// event always stands alone.
    static func group(_ items: [Item], focus: Set<String>) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        func key(_ it: Item) -> String {
            isStudyItem(it, focus: focus) ? "s|\(it.course ?? "")|\(it.category ?? "")" : "l|\(it.category ?? "")"
        }
        while i < items.count {
            let it = items[i]
            var block = Block(start: it.start, end: it.end, category: it.category, course: it.course, event: it.event,
                              study: isStudyItem(it, focus: focus), moments: it.moment.map { [$0] } ?? [],
                              interruptions: [], fixes: [], running: it.running, minutes: it.minutes)
            var j = i + 1
            if it.event == nil {
                while j < items.count {
                    let next = items[j]
                    guard next.event == nil, next.start.timeIntervalSince(block.end) <= 15 * 60 else { break }
                    if key(next) == key(it) {
                        if block.study, next.evidence != it.evidence, max(next.minutes, it.minutes) > 15,
                           !(next.evidence ? it : next).running { break }
                        block.end = max(block.end, next.end)
                        if let m = next.moment { block.moments.append(m) }
                        block.minutes += next.minutes
                        block.running = block.running || next.running
                        j += 1
                        continue
                    }
                    if block.study, !isStudyItem(next, focus: focus), next.minutes <= 5, next.category != "Break",
                       next.category != "Sleep",
                       let after = items[(j + 1)...].first(where: { $0.start >= next.start }),
                       key(after) == key(it), after.start.timeIntervalSince(next.end) <= 15 * 60 {
                        if let m = next.moment { block.interruptions.append(m) }
                        else { block.interruptions.append(Moment(start: next.start, end: next.end, text: next.category ?? "",
                                                                  category: next.category)) }
                        j += 1
                        continue
                    }
                    break
                }
            }
            blocks.append(block)
            i = j
        }
        return blocks
    }

    // MARK: Fixes

    static func isUntracked(_ f: Fix) -> Bool {
        if case .untracked = f.kind { return true }
        return false
    }

    static func fixList(tracked: [Tracked], events: [CalendarEvent], screen: [Screen], items: [Item],
                        focus: Set<String>, dayStart: Date, dayEnd: Date) -> [Fix] {
        var fixes: [Fix] = []
        for e in events where e.start < dayEnd {
            for t in tracked where t.label != "Class" {
                let a = max(e.start, t.start), b = min(e.end, t.end, dayEnd)
                guard b.timeIntervalSince(a) >= 10 * 60 else { continue }
                fixes.append(Fix(kind: .calendar(event: e.title), start: a, end: b, tracked: t.label, suggestion: "Class",
                                 running: t.running && b >= t.end))
            }
        }
        if let first = tracked.first?.start {
            var cursor = first
            for t in tracked {
                if t.start.timeIntervalSince(cursor) >= 10 * 60 {
                    fixes.append(untracked(cursor, t.start, items: items, focus: focus))
                }
                cursor = max(cursor, t.end)
            }
            if dayEnd.timeIntervalSince(cursor) >= 10 * 60, tracked.last?.running == false,
               items.contains(where: { $0.evidence && $0.start >= cursor }) {
                fixes.append(untracked(cursor, dayEnd, items: items, focus: focus))
            }
        }
        let classTimes = events.map { ($0.start, $0.end) }
        let observed = screen.map { MorningReviewPlanner.Observation(start: $0.start, end: $0.end, category: $0.category,
                                                                      uncertain: $0.uncertain) }
        let tracking = tracked.map { MorningReviewPlanner.Tracking(start: $0.start, end: $0.end, category: $0.label) }
        for c in MorningReviewPlanner.candidates(observations: observed, tracking: tracking, reviewed: [],
                                                 from: dayStart, to: dayEnd, minimumMinutes: 10) {
            guard let seen = c.screen, let tr = c.tracked, !c.uncertain, !c.overlappingTracking, tr != "Class",
                  tr != "Sleep", !classTimes.contains(where: { $0.0 < c.end && $0.1 > c.start }) else { continue }
            let running = tracked.contains { $0.running && $0.start <= c.start && c.end >= $0.end.addingTimeInterval(-60) }
            fixes.append(Fix(kind: .screenDiffers(seen: seen), start: c.start, end: c.end, tracked: tr, suggestion: seen,
                             running: running))
        }
        return fixes.sorted {
            let ra = rank($0.kind), rb = rank($1.kind)
            return ra != rb ? ra < rb : ($0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.start < $1.start)
        }
    }

    private static func rank(_ k: Fix.Kind) -> Int {
        switch k {
        case .calendar: return 0
        case .untracked(let seen): return seen == nil ? 2 : 1
        case .screenDiffers: return 2
        }
    }

    private static func untracked(_ a: Date, _ b: Date, items: [Item], focus: Set<String>) -> Fix {
        var minutes: [String: Double] = [:]
        for it in items where it.evidence {
            guard let c = it.moment?.category ?? it.category, focus.contains(c) else { continue }
            minutes[c, default: 0] += overlap((it.start, it.end), (a, b)) / 60
        }
        let seen = minutes.filter { $0.value >= 5 }.max { $0.value < $1.value }?.key
        return Fix(kind: .untracked(seen: seen), start: a, end: b, tracked: nil, suggestion: seen)
    }

    // MARK: Courses

    static func courses(blocks: [Block], record: CoachDay.Record?, observations: [CoachEpisode.Record],
                        course: (CoachEpisode.Record) -> String?, known: Set<String>, prefixes: [String: String],
                        focus: Set<String>) -> [Course] {
        var byCode: [String: Course] = [:]
        var order: [String] = []
        func touch(_ code: String, category: String) {
            if byCode[code] == nil {
                byCode[code] = Course(code: code, category: category, minutes: 0, topics: [], shaky: [], digest: nil,
                                      activity: [:])
                order.append(code)
            }
        }
        for b in blocks where b.study {
            guard let code = b.course, let category = b.category else { continue }
            touch(code, category: category)
            byCode[code]!.minutes += b.moments.reduce(0) { $0 + $1.minutes }
        }
        for s in record?.content.study ?? [] {
            guard let raw = s.course, let code = codes(raw, prefixes: prefixes).first.map({ canonical($0, known: known) })
            else { continue }
            touch(code, category: s.category)
            byCode[code]!.topics = s.topics
            byCode[code]!.shaky = s.shaky
            byCode[code]!.digest = s.digest
        }
        for r in observations where studyActivities.contains(r.understanding.activity) {
            let tr = r.source.trackedCategory ?? r.source.category
            guard let c = course(r).flatMap({ codes($0, prefixes: prefixes).first }).map({ canonical($0, known: known) })
                    ?? sole(order: order, byCode: byCode, category: tr) else { continue }
            touch(c, category: tr ?? "Study")
            byCode[c]!.activity[r.understanding.activity, default: 0] += 1
            if byCode[c]!.digest == nil {
                for concept in r.understanding.concepts where !byCode[c]!.topics.contains(concept) && byCode[c]!.topics.count < 8 {
                    byCode[c]!.topics.append(concept)
                }
            }
        }
        return order.compactMap { byCode[$0] }.filter { $0.minutes >= 3 || $0.digest != nil || $0.observations >= 3 }
            .sorted { $0.minutes > $1.minutes }
    }

    /// The only course seen today in a category, for observations that didn't name one.
    private static func sole(order: [String], byCode: [String: Course], category: String?) -> String? {
        guard let category else { return nil }
        let matches = order.filter { byCode[$0]?.category == category }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: Helpers

    static func codes(_ text: String, prefixes: [String: String]) -> [String] {
        StudyRecall.courseCodes(in: text, prefixes: prefixes)
    }

    /// "CPSC 3231" and "CPSC 323" are one course when either is the record's name for it.
    static func canonical(_ code: String, known: Set<String>) -> String {
        if known.contains(code) { return code }
        let parts = code.split(separator: " ")
        guard parts.count == 2 else { return code }
        let letters = parts[0], number = parts[1]
        return known.first { k in
            let kp = k.split(separator: " ")
            guard kp.count == 2, kp[0] == letters else { return false }
            return kp[1].hasPrefix(number) || number.hasPrefix(kp[1])
        } ?? code
    }

    static func clock(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return calendar.date(byAdding: .minute, value: parts[0] * 60 + parts[1], to: day)
    }

    static func trackedLabel(_ tracked: [Tracked], at a: Date, end b: Date) -> String? {
        var best: (String, TimeInterval)?
        for t in tracked {
            let o = overlap((t.start, t.end), (a, max(b, a.addingTimeInterval(1))))
            if o > 0, o > (best?.1 ?? 0) { best = (t.label, o) }
        }
        return best?.0
    }

    static func overlap(_ x: (Date, Date), _ y: (Date, Date)) -> TimeInterval {
        max(0, min(x.1, y.1).timeIntervalSince(max(x.0, y.0)))
    }

    static func subtract(_ range: (Date, Date), _ cuts: [(Date, Date)]) -> [(Date, Date)] {
        var pieces = [range]
        for c in cuts {
            pieces = pieces.flatMap { p -> [(Date, Date)] in
                guard c.0 < p.1, c.1 > p.0 else { return [p] }
                var out: [(Date, Date)] = []
                if c.0 > p.0 { out.append((p.0, c.0)) }
                if c.1 < p.1 { out.append((c.1, p.1)) }
                return out
            }
        }
        return pieces
    }

    static func split(_ range: (Date, Date), at events: [CalendarEvent]) -> [(Date, Date)] {
        var marks = Set([range.0, range.1])
        for e in events {
            if e.start > range.0 && e.start < range.1 { marks.insert(e.start) }
            if e.end > range.0 && e.end < range.1 { marks.insert(e.end) }
        }
        let sorted = marks.sorted()
        return zip(sorted, sorted.dropFirst()).map { ($0, $1) }
    }

    static func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for v in values where !v.isEmpty {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        return order.enumerated().sorted {
            counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset
        }.map(\.element)
    }
}
