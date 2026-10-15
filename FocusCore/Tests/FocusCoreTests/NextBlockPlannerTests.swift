import XCTest
@testable import FocusCore

final class NextBlockPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))! }

    func testExplicitStartWithHasPriorityAndNoInventedTarget() {
        let plan = NextBlockPlanner.suggest(on: today, startWith: "  Prove lemma 3  ", commitment: "Finish pset", exams: [], calendar: calendar)
        XCTAssertEqual(plan?.action, "Prove lemma 3")
        XCTAssertEqual(plan?.target, "")
        XCTAssertNil(plan?.category)
    }
    func testCommitmentUsesOneStepWithoutGuessingHoursOrCategory() {
        let plan = NextBlockPlanner.suggest(on: today, startWith: " ", commitment: "Solve pset 5 problem 1; review notes", exams: [], calendar: calendar)
        XCTAssertEqual(plan?.action, "Solve pset 5 problem 1")
        XCTAssertNil(plan?.category)
    }
    func testExamFallbackOnlyUsesUpcomingWeekAndStillAsksForTopic() {
        let exam = NextBlockPlanner.Exam(title: "Math midterm", date: today.addingTimeInterval(86400), category: "Math")
        let past = NextBlockPlanner.Exam(title: "Past exam", date: today.addingTimeInterval(-86400), category: "SWE")
        let plan = NextBlockPlanner.suggest(on: today, startWith: nil, commitment: nil, exams: [past, exam], calendar: calendar)
        XCTAssertEqual(plan?.category, "Math")
        XCTAssertEqual(plan?.action, "Choose one topic to review for Math midterm")
        XCTAssertEqual(plan?.target, "")
        XCTAssertNil(NextBlockPlanner.suggest(on: today, startWith: nil, commitment: nil, exams: [past], calendar: calendar))
        XCTAssertNil(NextBlockPlanner.suggest(on: today, startWith: nil, commitment: nil,
            exams: [.init(title: "Distant", date: today.addingTimeInterval(10 * 86400), category: nil)], calendar: calendar))
    }
}
