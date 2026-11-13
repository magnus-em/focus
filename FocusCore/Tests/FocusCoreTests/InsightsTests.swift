import XCTest
@testable import FocusCore

final class InsightsTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    lazy var day = cal.date(from: DateComponents(year: 2026, month: 11, day: 3))!
    func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
    func seg(_ a: Double, _ b: Double, _ app: String, _ c: String?, title: String? = nil) -> WindowTimeline.LabeledSegment {
        .init(segment: .init(start: at(a), end: at(b), app: app, bundle: app, title: title ?? app), category: c, source: .reading)
    }

    func input() -> Insights.Input {
        let study: Set<String> = ["Math", "SWE", "AI", "HW", "LeetCode"]
        return Insights.Input(
            period: DateInterval(start: day, end: day.addingTimeInterval(7 * 86400)),
            goals: Goals.seed(now: day).goals,
            sessions: [
                .init(start: at(9), end: at(10), category: "Math", isFocus: true),
                .init(start: at(10), end: at(12), category: "AI", isFocus: true),
                .init(start: at(12), end: at(13), category: "Meals", isFocus: false),
            ],
            segments: [
                seg(9, 9 + 40.0 / 60, "Preview", "Math", title: "pset6.pdf"),
                seg(9 + 40.0 / 60, 9 + 41.0 / 60, "Messages", "Private"),
                seg(9 + 41.0 / 60, 10, "Preview", "Math", title: "pset6.pdf"),
                seg(10, 11, "Code", "AI"),
                seg(11, 11 + 5.0 / 60, "Google Chrome", "Leisure", title: "(3) Home / X"),
                seg(11 + 5.0 / 60, 12, "Code", "AI"),
            ],
            observations: [
                .init(at: at(9), end: at(10), category: "Math", course: "MATH 244", activity: "solving", asked: ["why is this a bijection"], concepts: ["bijection"]),
                .init(at: at(10), end: at(12), category: "AI", course: "CPSC 7770", activity: "asking", concepts: ["linear attention"]),
            ],
            leetCodeSolves: [], studyCategories: study, lifeCategories: ["Leisure", "Admin", "Meals", "Social"])
    }

    func testEffortGoesByGoalAndAvoidedComesFirst() {
        let s = Insights.summarize(input(), calendar: cal)
        XCTAssertEqual(s.goals.map(\.title), ["Recruiting", "Homework", "Deep learning"])
        XCTAssertEqual(s.goals[0].screenMinutes, 0)
        XCTAssertEqual(s.goals[1].screenMinutes, 59, accuracy: 0.01)
        XCTAssertEqual(s.goals[1].trackedMinutes, 60, accuracy: 0.01)
        XCTAssertEqual(s.goals[2].screenMinutes, 115, accuracy: 0.01)
        XCTAssertEqual(s.avoidedMinutes, 59, accuracy: 0.01)
        XCTAssertEqual(s.avoidedShare, 59.0 / 174, accuracy: 0.001)
        XCTAssertEqual(s.avoidedFirstDays, 1)
        XCTAssertEqual(s.goals[1].perDay.first ?? 0, 59, accuracy: 0.01)
        XCTAssertEqual(s.goals[0].outputs["leetCodeProblems"], 0)
        XCTAssertEqual(s.courseMinutes["MATH 244"] ?? 0, 59, accuracy: 0.01)
    }

    func testTimerAgainstScreenAndAttention() {
        let s = Insights.summarize(input(), calendar: cal)
        XCTAssertEqual(s.trackedFocusMinutes, 180, accuracy: 0.01)
        XCTAssertEqual(s.confirmedMinutes, 174, accuracy: 0.01)
        XCTAssertEqual(s.offTaskMinutes, 6, accuracy: 0.01)
        XCTAssertEqual(s.unseenMinutes, 0, accuracy: 0.01)
        XCTAssertEqual(s.attention.distractions, 2)
        XCTAssertEqual(s.attention.distractors.map(\.name).sorted(), ["Messages", "X"])
        XCTAssertEqual(s.attention.perFocusHour, 2.0 / 3, accuracy: 0.01)
        XCTAssertEqual(s.attention.longestStretchMinutes, 60, accuracy: 0.01)
        XCTAssertEqual(s.days.first?.longestStretch ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(s.days.first?.distractionsPerHour ?? 0, 2.0 / 3, accuracy: 0.01)
    }

    func testStudyMixAndQuestions() {
        let s = Insights.summarize(input(), calendar: cal)
        XCTAssertEqual(s.questions, 1)
        XCTAssertEqual(Set(s.activityMinutes.keys), ["solving", "asking"])
        XCTAssertTrue(s.repeatedConcepts.isEmpty)
    }
}
