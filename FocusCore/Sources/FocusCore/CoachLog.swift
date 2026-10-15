import Foundation

/// Small append-only logs the coach learns from, in `Focus/coach/`:
/// how sure the user was before seeing an answer (calibration: rereading and
/// watching inflate confidence, a delayed self-test shows the truth), and a
/// short debrief the morning after an exam.
public enum CoachLog {
    public struct Calibration: Codable, Equatable, Sendable {
        public var at: Date
        public var course: String?
        public var topic: String
        /// 1 not sure, 2 fairly sure, 3 sure.
        public var confidence: Int
        /// `RecallGrade.rawValue`.
        public var grade: Int

        public init(at: Date, course: String?, topic: String, confidence: Int, grade: Int) {
            self.at = at
            self.course = course
            self.topic = topic
            self.confidence = confidence
            self.grade = grade
        }
    }

    public struct ExamDebrief: Codable, Equatable, Sendable {
        public var at: Date
        public var exam: String
        public var examDate: Date
        /// 1 rough … 5 great.
        public var rating: Int
        public var surprised: String
        public var differently: String

        public init(at: Date, exam: String, examDate: Date, rating: Int, surprised: String, differently: String) {
            self.at = at
            self.exam = exam
            self.examDate = examDate
            self.rating = rating
            self.surprised = surprised
            self.differently = differently
        }
    }

    public static func append<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let line = try e.encode(value) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? d.decode(T.self, from: Data($0.utf8)) }
    }

    /// "When you were sure, you were right 4 of 6 times." nil until there
    /// are at least `minimum` sure answers.
    public static func sureSummary(_ entries: [Calibration], minimum: Int = 5) -> String? {
        let sure = entries.filter { $0.confidence == 3 }
        guard sure.count >= minimum else { return nil }
        let right = sure.filter { $0.grade >= RecallGrade.got.rawValue }.count
        return "When you were sure, you were right \(right) of \(sure.count) times."
    }
}
