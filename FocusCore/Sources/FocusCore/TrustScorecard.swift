import Foundation

public enum TrustScorecard {
    public enum Mode: String, CaseIterable, Sendable { case normal, test, unknown }
    public struct Observation {
        public let start: Date, end: Date
        public let category: String?
        public let mode: Mode
        public init(start: Date, end: Date, category: String?, mode: Mode) {
            self.start = start; self.end = end; self.category = category; self.mode = mode
        }
    }
    public struct Check {
        public let right: Bool
        public let mode: Mode
        public init(right: Bool, mode: Mode) { self.right = right; self.mode = mode }
    }
    public struct Card {
        public let shown: Date, since: Date?
        public let answer: String?
        public let automatic: Bool
        public let mode: Mode
        public init(shown: Date, since: Date?, answer: String?, automatic: Bool, mode: Mode) {
            self.shown = shown; self.since = since; self.answer = answer; self.automatic = automatic; self.mode = mode
        }
    }
    public struct Score {
        public init() {}
        public var checked = 0, right = 0
        public var agreeingSeconds: Double = 0, comparedSeconds: Double = 0
        public var switched = 0, kept = 0, dismissed = 0, ignored = 0, pending = 0
        public var automatic = 0, undone = 0
        public var delays: [Double] = []
        public var medianDelay: Double? {
            let values = delays.sorted()
            guard !values.isEmpty else { return nil }
            let i = values.count / 2
            return values.count % 2 == 0 ? (values[i - 1] + values[i]) / 2 : values[i]
        }
    }
    public static func score(mode: Mode, observations: [Observation], tracking: [WorkSession],
                             checks: [Check], cards: [Card], from: Date, to: Date, now: Date) -> Score {
        var result = Score()
        let end = min(to, now)
        for check in checks where check.mode == mode {
            result.checked += 1
            if check.right { result.right += 1 }
        }
        let rows = tracking.filter { $0.durationMinutes.isFinite && $0.durationMinutes > 0 }
        let spans = observations.filter { $0.mode == mode && $0.category != nil && $0.end > from && $0.start < end }
        // Sweep interval edges; conflicting labels are excluded and repeated
        // device evidence cannot count the same second twice.
        struct Edge { let label: String; let screen: Bool; let delta: Int }
        var events: [Date: [Edge]] = [:]
        func add(_ a: Date, _ b: Date, _ label: String, screen: Bool) {
            let a = max(a, from), b = min(b, end)
            guard b > a else { return }
            events[a, default: []].append(Edge(label: label, screen: screen, delta: 1))
            events[b, default: []].append(Edge(label: label, screen: screen, delta: -1))
        }
        for span in spans { add(span.start, span.end, span.category!, screen: true) }
        for row in rows {
            add(row.startTime, row.startTime.addingTimeInterval(row.durationMinutes * 60),
                row.type.isBreak ? "Break" : row.label ?? "Focus", screen: false)
        }
        var screenLabels: [String: Int] = [:], trackedLabels: [String: Int] = [:]
        var previous: Date?
        for date in events.keys.sorted() {
            if let previous, screenLabels.count == 1, trackedLabels.count == 1 {
                result.comparedSeconds += date.timeIntervalSince(previous)
                if screenLabels.keys.first == trackedLabels.keys.first { result.agreeingSeconds += date.timeIntervalSince(previous) }
            }
            for edge in events[date]! {
                if edge.screen {
                    screenLabels[edge.label, default: 0] += edge.delta
                    if screenLabels[edge.label] == 0 { screenLabels[edge.label] = nil }
                } else {
                    trackedLabels[edge.label, default: 0] += edge.delta
                    if trackedLabels[edge.label] == 0 { trackedLabels[edge.label] = nil }
                }
            }
            previous = date
        }
        for card in cards where card.mode == mode && card.shown >= from && card.shown < end {
            if let since = card.since, since <= card.shown {
                result.delays.append(card.shown.timeIntervalSince(since))
            }
            if card.automatic {
                guard card.answer != nil || now.timeIntervalSince(card.shown) >= 45 else { result.pending += 1; continue }
                result.automatic += 1
                if card.answer?.hasPrefix("undid") == true { result.undone += 1 }
            } else if let answer = card.answer {
                if answer.hasPrefix("switched") || answer.hasPrefix("changed") { result.switched += 1 }
                else if answer.hasPrefix("kept") { result.kept += 1 }
                else { result.dismissed += 1 }
            } else if now.timeIntervalSince(card.shown) >= 15 * 60 { result.ignored += 1 }
            else { result.pending += 1 }
        }
        return result
    }
}
