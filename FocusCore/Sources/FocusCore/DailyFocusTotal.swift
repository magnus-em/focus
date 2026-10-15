import Foundation

public enum DailyFocusTotal {
    public struct Live: Sendable {
        public let start: Date
        public let activeSeconds: TimeInterval
        public let label: String
        public let isBreak: Bool

        public init(start: Date, activeSeconds: TimeInterval, label: String, isBreak: Bool) {
            self.start = start
            self.activeSeconds = activeSeconds
            self.label = label
            self.isBreak = isBreak
        }
    }

    public static func categoryMinutes(saved: [WorkSession], live: Live?, on day: Date, through now: Date,
                                       lifeTags: Set<String>, calendar: Calendar = .current) -> [String: Double] {
        let session: WorkSession? = live.flatMap { live in
            guard live.activeSeconds.isFinite, live.activeSeconds > 0 else { return nil }
            let seconds = min(live.activeSeconds, max(0, now.timeIntervalSince(live.start)))
            return WorkSession(startTime: live.start, durationMinutes: seconds / 60,
                               type: live.isBreak ? .shortBreak : .work,
                               label: live.label.isEmpty ? "Focus" : live.label)
        }
        return FocusStats.focusCategoryMinutes(saved, live: session, on: day, through: now,
                                                lifeTags: lifeTags, calendar: calendar)
    }
}
