import XCTest
@testable import FocusCore

final class GoalsTests: XCTestCase {
    func testSeedPutsTheWorkYouAvoidFirst() {
        let d = Goals.seed()
        XCTAssertEqual(d.active.map(\.title), ["Recruiting", "Homework", "Deep learning"])
        XCTAssertEqual(d.active.filter(\.avoided).map(\.title), ["Recruiting", "Homework"])
        XCTAssertTrue(SyncedDefaults.syncedKeys.contains(Goals.key))
    }

    func testCourseBeatsCategory() {
        let goals = Goals.seed().goals
        XCTAssertEqual(Goals.goal(for: "SWE", course: "CPSC 3231", in: goals)?.title, "Homework")
        XCTAssertEqual(Goals.goal(for: "AI", course: "CPSC 7770", in: goals)?.title, "Deep learning")
        XCTAssertEqual(Goals.goal(for: "LeetCode", course: nil, in: goals)?.title, "Recruiting")
        XCTAssertNil(Goals.goal(for: "SWE", course: nil, in: goals))
        XCTAssertNil(Goals.goal(for: "Leisure", course: nil, in: goals))
    }

    func testRoundTripAndHistoryWording() {
        let old = Goals.seed()
        var new = old
        new.goals.swapAt(0, 1)
        new.goals[1].weeklyHours = 8
        new.goals[2].avoided = true
        XCTAssertEqual(Goals.Document.decode(new.encoded()), new)
        let lines = Goals.describe(from: old, to: new)
        XCTAssertTrue(lines.contains("Made Homework #1"))
        XCTAssertTrue(lines.contains("Recruiting: weekly target 8 h"))
        XCTAssertTrue(lines.contains("Deep learning: marked as put off"))
    }
}
