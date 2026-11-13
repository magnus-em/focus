import Foundation

/// What was in front, to the second: one row per app/window/tab change,
/// keyboard/mouse counts every 5 s, a heartbeat every 20 s and away marks
/// (`Focus/timeline/YYYY-MM-DD.jsonl`). No screenshots, so it's cheap enough
/// to run every second; the 15 s screen readings supply what each window was
/// about, and this supplies exactly when it was in front.
public enum WindowTimeline {
    public static let inputBucket: TimeInterval = 5
    public static let aliveEvery: TimeInterval = 20
    /// Longer than this with no row at all means the recorder wasn't running
    /// (sleep, quit, a stall), so nothing is assumed about that time.
    public static let recorderGap: TimeInterval = 30

    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case window, input, alive, away }
        public var at: Date
        public var kind: Kind
        public var app: String?
        public var bundle: String?
        public var title: String?
        public var url: String?
        public var keys: Int?
        public var clicks: Int?
        public var scrolls: Int?
        public var moves: Int?
        public var reason: String?

        enum CodingKeys: String, CodingKey {
            case at, kind, app, bundle, title, url, reason
            case keys = "k", clicks = "c", scrolls = "s", moves = "m"
        }

        public init(at: Date, kind: Kind, app: String? = nil, bundle: String? = nil, title: String? = nil,
                    url: String? = nil, keys: Int? = nil, clicks: Int? = nil, scrolls: Int? = nil,
                    moves: Int? = nil, reason: String? = nil) {
            self.at = at; self.kind = kind; self.app = app; self.bundle = bundle; self.title = title
            self.url = url; self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.moves = moves
            self.reason = reason
        }

        public static func window(_ at: Date, app: String, bundle: String, title: String?, url: String? = nil) -> Event {
            Event(at: at, kind: .window, app: app, bundle: bundle, title: title, url: url)
        }
        public static func input(_ at: Date, keys: Int, clicks: Int, scrolls: Int, moves: Int) -> Event {
            Event(at: at, kind: .input, keys: keys, clicks: clicks, scrolls: scrolls, moves: moves)
        }
        public static func alive(_ at: Date) -> Event { Event(at: at, kind: .alive) }
        public static func away(_ at: Date, reason: String) -> Event { Event(at: at, kind: .away, reason: reason) }
    }

    /// One stretch of one window in front.
    public struct Segment: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var app: String
        public var bundle: String
        public var title: String?
        public var url: String?
        /// Seconds of 5 s buckets that had any keyboard/mouse input.
        public var inputSeconds: Double = 0
        public var keys = 0
        public var clicks = 0
        public var scrolls = 0

        public var seconds: Double { end.timeIntervalSince(start) }
        public var key: String { bundle + "|" + (title ?? "") }

        public init(start: Date, end: Date, app: String, bundle: String, title: String? = nil, url: String? = nil,
                    inputSeconds: Double = 0, keys: Int = 0, clicks: Int = 0, scrolls: Int = 0) {
            self.start = start; self.end = end; self.app = app; self.bundle = bundle; self.title = title
            self.url = url; self.inputSeconds = inputSeconds; self.keys = keys; self.clicks = clicks
            self.scrolls = scrolls
        }
    }

    /// Spinners and progress glyphs in terminal and agent titles change every
    /// second; they aren't a different window.
    public static func normalizedTitle(_ title: String) -> String {
        let dropped = title.unicodeScalars.filter { s in
            !(0x2800...0x28FF).contains(s.value) && !"◐◓◑◒✶✳✻✽✢·⏺".unicodeScalars.contains(s)
        }
        return String(String.UnicodeScalarView(dropped)).trimmingCharacters(in: .whitespaces)
    }

    public static func segments(_ events: [Event], away: [DateInterval] = [], from: Date, to: Date) -> [Segment] {
        let sorted = events.sorted { $0.at < $1.at }
        var out: [Segment] = []
        var cur: Segment?
        var last: Date?
        func close(at t: Date) {
            guard var s = cur else { return }
            s.end = max(s.start, t)
            if s.end > s.start { out.append(s) }
            cur = nil
        }
        for e in sorted {
            if let l = last, e.at.timeIntervalSince(l) > recorderGap, var s = cur {
                close(at: l)
                s.start = e.at; s.end = e.at; s.inputSeconds = 0; s.keys = 0; s.clicks = 0; s.scrolls = 0
                cur = s
            }
            switch e.kind {
            case .window:
                let open = cur
                close(at: e.at)
                if let b = e.bundle {
                    cur = Segment(start: e.at, end: e.at, app: e.app ?? b, bundle: b, title: e.title, url: e.url)
                } else { cur = open.map { var s = $0; s.start = e.at; s.end = e.at; return s } }
            case .away:
                close(at: e.at)
            case .input:
                if cur != nil {
                    let any = (e.keys ?? 0) + (e.clicks ?? 0) + (e.scrolls ?? 0) + (e.moves ?? 0) > 0
                    if any { cur!.inputSeconds += inputBucket }
                    cur!.keys += e.keys ?? 0
                    cur!.clicks += e.clicks ?? 0
                    cur!.scrolls += e.scrolls ?? 0
                }
            case .alive:
                break
            }
            last = e.at
        }
        if let l = last {
            close(at: to.timeIntervalSince(l) <= recorderGap ? to : l)
        }
        return clip(subtract(out, away), from: from, to: to)
    }

    static func subtract(_ segs: [Segment], _ away: [DateInterval]) -> [Segment] {
        guard !away.isEmpty else { return segs }
        let gaps = away.sorted { $0.start < $1.start }
        var out: [Segment] = []
        for s in segs {
            var pieces = [s]
            for g in gaps where g.end > s.start && g.start < s.end {
                pieces = pieces.flatMap { p -> [Segment] in
                    guard g.end > p.start, g.start < p.end else { return [p] }
                    var r: [Segment] = []
                    if g.start > p.start { var a = p; a.end = g.start; r.append(a) }
                    if g.end < p.end { var b = p; b.start = g.end; b.inputSeconds = 0; r.append(b) }
                    return r
                }
            }
            out += pieces
        }
        return out
    }

    static func clip(_ segs: [Segment], from: Date, to: Date) -> [Segment] {
        segs.compactMap { s in
            guard s.end > from, s.start < to else { return nil }
            var c = s
            let full = s.seconds
            c.start = max(s.start, from); c.end = min(s.end, to)
            if full > 0, c.seconds < full { c.inputSeconds = min(c.seconds, s.inputSeconds * c.seconds / full) }
            return c
        }
    }

    // MARK: - Labels

    /// A screen reading's label over a stretch (from `screen.json`).
    public struct Label: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var bundle: String
        public var title: String
        public var category: String?
        /// Where the label came from ("you", "model", "rule" for the Focus-project rule…).
        public var source: String?
        public init(start: Date, end: Date, bundle: String, title: String, category: String?, source: String? = nil) {
            self.start = start; self.end = end; self.bundle = bundle; self.title = title; self.category = category
            self.source = source
        }
    }

    public struct LabeledSegment: Equatable, Sendable {
        public enum Source: String, Sendable { case reading, sameWindow, sameApp, privateApp, none }
        public var segment: Segment
        public var category: String?
        public var source: Source
        /// From 15 s screen readings (before the window log), whose spans
        /// have processing holes of up to 2 min between them.
        public var coarse = false
        public var labelSource: String?

        public init(segment: Segment, category: String?, source: Source, coarse: Bool = false, labelSource: String? = nil) {
            self.segment = segment; self.category = category; self.source = source; self.coarse = coarse
            self.labelSource = labelSource
        }
    }

    public static let privateCategory = "Private"

    /// Each segment takes the label of the screen readings of the same app
    /// during it; a glance too short for a reading takes the latest label of
    /// the same window (4 h) or app (10 min). Private apps are "Private".
    public static func label(_ segments: [Segment], with labels: [Label], privateBundles: Set<String>) -> [LabeledSegment] {
        var byBundle: [String: [Label]] = [:]
        for l in labels { byBundle[l.bundle, default: []].append(l) }
        for k in byBundle.keys { byBundle[k]!.sort { $0.start < $1.start } }
        return segments.map { s in
            if privateBundles.contains(s.bundle) { return LabeledSegment(segment: s, category: privateCategory, source: .privateApp) }
            let same = byBundle[s.bundle] ?? []
            var overlap: [String: Double] = [:]
            var sources: [String: String] = [:]
            for l in same where l.end > s.start && l.start < s.end {
                guard let c = l.category else { continue }
                overlap[c, default: 0] += min(l.end, s.end).timeIntervalSince(max(l.start, s.start))
                if let src = l.source { sources[c] = src }
            }
            if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
                return LabeledSegment(segment: s, category: best.key, source: .reading, labelSource: sources[best.key])
            }
            let before = same.filter { $0.start < s.end && $0.category != nil }
            if let t = s.title, !t.isEmpty,
               let l = before.last(where: { ($0.title == t || t.hasPrefix($0.title) || $0.title.hasPrefix(t))
                   && s.start.timeIntervalSince($0.end) < 4 * 3600 }) {
                return LabeledSegment(segment: s, category: l.category, source: .sameWindow, labelSource: l.source)
            }
            if let l = before.last, s.start.timeIntervalSince(l.end) < 600 {
                return LabeledSegment(segment: s, category: l.category, source: .sameApp, labelSource: l.source)
            }
            return LabeledSegment(segment: s, category: nil, source: .none)
        }
    }

    // MARK: - Excursions

    /// A tracked block of one category (from the timer).
    public struct Block: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var category: String
        public init(start: Date, end: Date, category: String) { self.start = start; self.end = end; self.category = category }
    }
}
