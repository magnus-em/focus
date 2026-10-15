import XCTest
@testable import FocusCore

final class CoachLogTests: XCTestCase {
    func testAppendReadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = CoachLog.Calibration(at: Date(timeIntervalSince1970: 1_800_000_000), course: "MATH 244", topic: "posets",
                                     confidence: 3, grade: RecallGrade.got.rawValue)
        try CoachLog.append(a, to: url)
        try CoachLog.append(a, to: url)
        XCTAssertEqual(CoachLog.read(CoachLog.Calibration.self, from: url), [a, a])
    }

    func testSureSummaryNeedsEnoughAnswers() {
        func c(_ confidence: Int, _ grade: RecallGrade) -> CoachLog.Calibration {
            .init(at: Date(), course: nil, topic: "t", confidence: confidence, grade: grade.rawValue)
        }
        let few = [c(3, .got), c(3, .forgot), c(1, .forgot)]
        XCTAssertNil(CoachLog.sureSummary(few))
        let more = few + [c(3, .fluent), c(3, .partial), c(3, .got), c(3, .forgot)]
        XCTAssertEqual(CoachLog.sureSummary(more), "When you were sure, you were right 3 of 6 times.")
    }
}
