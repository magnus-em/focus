import XCTest
@testable import FocusCore

final class MorningReviewTests: XCTestCase {
    private func date(_ minute: Double) -> Date { Date(timeIntervalSince1970: minute * 60) }

    func testSplitsAtTrackedSwitchAndRanksLongestFirst() {
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: date(0), end: date(30), category: "Math")],
            tracking: [.init(start: date(0), end: date(10), category: "Math"),
                       .init(start: date(10), end: date(30), category: "SWE")],
            reviewed: [], from: date(0), to: date(30))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, date(10))
        XCTAssertEqual(result.first?.minutes, 20)
        XCTAssertEqual(result.first?.tracked, "SWE")
    }

    func testPartialReviewDoesNotHideTheRestOrBridgeAGap() {
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: date(0), end: date(10), category: nil),
                           .init(start: date(12), end: date(20), category: nil)],
            tracking: [], reviewed: [DateInterval(start: date(0), end: date(4))],
            from: date(0), to: date(20))
        XCTAssertEqual(result.map(\.minutes), [8, 6])
        XCTAssertEqual(result.last?.start, date(4))
    }

    func testMergesContiguousUnknownSnapshotsAndIncludesUncertainty() {
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: date(0), end: date(0.5), category: nil),
                           .init(start: date(0.5), end: date(1.5), category: nil),
                           .init(start: date(2), end: date(4), category: "Math", uncertain: true)],
            tracking: [.init(start: date(0), end: date(4), category: "Math")],
            reviewed: [], from: date(0), to: date(4))
        XCTAssertEqual(result.map(\.minutes), [2, 1.5])
        XCTAssertTrue(result[0].uncertain)
    }

    func testClipsWindowAndProtectsRunningInterval() {
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: date(-30), end: date(40), category: "Math")],
            tracking: [], reviewed: [], from: date(0), to: date(15))
        XCTAssertEqual(result.first?.start, date(0))
        XCTAssertEqual(result.first?.end, date(15))
    }

    func testOverlappingLabelsAreNotTreatedAsGroundTruth() {
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: date(0), end: date(10), category: "Math")],
            tracking: [.init(start: date(0), end: date(10), category: "Math"),
                       .init(start: date(0), end: date(10), category: "SWE")],
            reviewed: [], from: date(0), to: date(10))
        XCTAssertTrue(result.first?.overlappingTracking == true)
        XCTAssertNil(result.first?.tracked)
    }

    func testCalendarDayWithDSTIsNotAssumedToBe24Hours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let result = MorningReviewPlanner.candidates(
            observations: [.init(start: start, end: end, category: nil)],
            tracking: [], reviewed: [], from: start, to: end)
        XCTAssertEqual(result.first?.minutes, 25 * 60)
    }
}
