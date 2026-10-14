import Foundation

public enum MorningReviewPlanner {
    public struct Observation: Sendable {
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

    public struct Tracking: Sendable {
        public var start: Date
        public var end: Date
        public var category: String

        public init(start: Date, end: Date, category: String) {
            self.start = start
            self.end = end
            self.category = category
        }
    }

    public struct Candidate: Equatable, Identifiable, Sendable {
        public var start: Date
        public var end: Date
        public var screen: String?
        public var tracked: String?
        public var uncertain: Bool
        public var overlappingTracking: Bool
        public init(start: Date, end: Date, screen: String?, tracked: String?, uncertain: Bool,
                    overlappingTracking: Bool) {
            self.start = start
            self.end = end
            self.screen = screen
            self.tracked = tracked
            self.uncertain = uncertain
            self.overlappingTracking = overlappingTracking
        }
        public var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
        public var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    public static func candidates(observations: [Observation], tracking: [Tracking],
                                  reviewed: [DateInterval], from: Date, to: Date,
                                  minimumMinutes: Double = 1) -> [Candidate] {
        guard to > from else { return [] }
        var pieces: [Candidate] = []
        for observation in observations.sorted(by: { $0.start < $1.start }) {
            let start = max(from, observation.start), end = min(to, observation.end)
            guard end > start else { continue }
            let overlapping = tracking.filter { $0.end > start && $0.start < end }
            let checked = reviewed.filter { $0.end > start && $0.start < end }
            var boundaries = Set([start, end])
            for interval in overlapping {
                boundaries.insert(max(start, interval.start))
                boundaries.insert(min(end, interval.end))
            }
            for interval in checked {
                boundaries.insert(max(start, interval.start))
                boundaries.insert(min(end, interval.end))
            }
            let sorted = boundaries.sorted()
            for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
                let midpoint = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                guard !checked.contains(where: { $0.start <= midpoint && midpoint < $0.end }) else { continue }
                let labels = Set(overlapping.filter { $0.start <= midpoint && midpoint < $0.end }.map(\.category))
                let tracked = labels.count == 1 ? labels.first : nil
                let conflict = labels.count > 1
                guard observation.category == nil || observation.uncertain || tracked == nil || tracked != observation.category else { continue }
                let candidate = Candidate(start: a, end: b, screen: observation.category, tracked: tracked,
                                          uncertain: observation.uncertain, overlappingTracking: conflict)
                if let last = pieces.last, last.end == a, last.screen == candidate.screen,
                   last.tracked == candidate.tracked, last.uncertain == candidate.uncertain,
                   last.overlappingTracking == candidate.overlappingTracking {
                    pieces[pieces.count - 1].end = b
                } else {
                    pieces.append(candidate)
                }
            }
        }
        return pieces.filter { $0.minutes >= minimumMinutes }.sorted {
            $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.start < $1.start
        }
    }
}
