import Foundation

public enum ScreenStretch {
    public struct Sample: Sendable {
        public let id: UUID
        public let start: Date, end: Date
        public let window: String, title: String, category: String?, taskKey: String
        public let active: Bool
        public let idleSeconds: Double
        public init(id: UUID, start: Date, end: Date, window: String, title: String, category: String?, taskKey: String,
                    active: Bool, idleSeconds: Double) {
            self.id = id; self.start = start; self.end = end; self.window = window; self.title = title
            self.category = category; self.taskKey = taskKey; self.active = active; self.idleSeconds = idleSeconds
        }
        public init(_ row: ScreenJournal.Row) {
            self.init(id: row.id, start: row.at, end: row.end, window: row.windowKey, title: row.title,
                      category: row.category, taskKey: row.bundle + "|" + (row.url ?? row.title), active: row.active, idleSeconds: row.idleSeconds)
        }
    }
    public struct Interval: Codable, Equatable, Sendable {
        public let start: Date, end: Date
    }
    public struct Stretch: Codable, Sendable {
        public let window: String, title: String, category: String?, taskKey: String
        public let active: Bool, idle: Bool
        public var intervals: [Interval]
        public var evidence: [UUID]
        public var start: Date { intervals.first!.start }
        public var end: Date { intervals.last!.end }
        public var seconds: Double { intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    }
    public struct TaskGroup: Sendable {
        public let taskKey: String, category: String?
        public var stretches: [Stretch]
        public var intervals: [Interval] { ScreenStretch.union(stretches.flatMap(\.intervals)) }
        public var seconds: Double { intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    }
    public struct Result: Sendable {
        public let stretches: [Stretch]
        public let gaps: [Interval]
        public let tasks: [TaskGroup]
    }

    public static func segment(_ samples: [Sample], maximumSeconds: Double = 600) -> Result {
        let limit = maximumSeconds.isFinite ? min(600, max(1, maximumSeconds)) : 600
        let ordered = samples.filter { $0.end > $0.start && $0.idleSeconds.isFinite && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        var stretches: [Stretch] = [], gaps: [Interval] = []
        var previousEnd: Date?
        for (index, sample) in ordered.enumerated() {
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].start : sample.end
            let end = min(sample.end, nextStart)
            guard end > sample.start else { continue }
            if let previousEnd, sample.start > previousEnd { gaps.append(.init(start: previousEnd, end: sample.start)) }
            var cursor = sample.start
            while cursor < end {
                let idle = sample.idleSeconds > 120
                if var last = stretches.last, last.end == cursor, last.window == sample.window, last.title == sample.title,
                   last.category == sample.category, last.taskKey == sample.taskKey, last.active == sample.active,
                   last.idle == idle, cursor.timeIntervalSince(last.start) < limit {
                    let stop = min(end, last.start.addingTimeInterval(limit))
                    guard stop > cursor else { break }
                    last.intervals = union(last.intervals + [.init(start: cursor, end: stop)])
                    if last.evidence.last != sample.id { last.evidence.append(sample.id) }
                    stretches[stretches.count - 1] = last
                    cursor = stop
                } else {
                    let stop = min(end, cursor.addingTimeInterval(limit))
                    guard stop > cursor else { break }
                    stretches.append(Stretch(window: sample.window, title: sample.title, category: sample.category,
                        taskKey: sample.taskKey, active: sample.active, idle: idle,
                        intervals: [.init(start: cursor, end: stop)], evidence: [sample.id]))
                    cursor = stop
                }
            }
            previousEnd = end
        }
        var tasks: [TaskGroup] = []
        for stretch in stretches {
            if let i = tasks.firstIndex(where: { $0.taskKey == stretch.taskKey && $0.category == stretch.category }) {
                tasks[i].stretches.append(stretch)
            } else { tasks.append(TaskGroup(taskKey: stretch.taskKey, category: stretch.category, stretches: [stretch])) }
        }
        return Result(stretches: stretches, gaps: union(gaps), tasks: tasks)
    }

    private static func union(_ input: [Interval]) -> [Interval] {
        var result: [Interval] = []
        for interval in input.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
}
