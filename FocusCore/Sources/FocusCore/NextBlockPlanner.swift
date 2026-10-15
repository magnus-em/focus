import Foundation

public enum NextBlockPlanner {
    public struct Plan: Codable, Equatable, Sendable {
        public var action: String
        public var category: String?
        public var target: String
        public var source: String
        public init(action: String, category: String? = nil, target: String = "", source: String) {
            self.action = action; self.category = category; self.target = target; self.source = source
        }
    }
    public struct Exam {
        public let title: String, date: Date, category: String?
        public init(title: String, date: Date, category: String?) {
            self.title = title; self.date = date; self.category = category
        }
    }
    public static func suggest(on day: Date, startWith: String?, commitment: String?, exams: [Exam],
                               calendar: Calendar = .current) -> Plan? {
        func clean(_ text: String?) -> String? {
            let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : String(value.prefix(240))
        }
        if let task = clean(startWith) { return Plan(action: task, source: "Your start-with note") }
        if let commitment = clean(commitment),
           let first = commitment.components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .compactMap({ clean($0) }).first {
            return Plan(action: first, source: "Your commitment — pick one concrete step")
        }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 8, to: start),
              let exam = exams.filter({ $0.date >= start && $0.date < end }).sorted(by: { $0.date < $1.date }).first,
              let title = clean(exam.title) else { return nil }
        return Plan(action: "Choose one topic to review for \(title)", category: exam.category,
                    source: "Upcoming exam — choose the assignment or concept")
    }
}
