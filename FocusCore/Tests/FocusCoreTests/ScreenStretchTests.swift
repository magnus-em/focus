import XCTest
@testable import FocusCore

final class ScreenStretchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ a: Double, _ b: Double, window: String = "w", title: String = "title", category: String = "Math", task: String = "same", idle: Double = 0) -> ScreenStretch.Sample {
        .init(id: UUID(), start: now.addingTimeInterval(a), end: now.addingTimeInterval(b), window: window, title: title,
              category: category, taskKey: task, active: idle < 90, idleSeconds: idle)
    }
    func testWindowTitleCategoryAndIdleBoundaries() {
        let result = ScreenStretch.segment([sample(0,15), sample(15,30, window:"other"), sample(30,45,title:"new"),
            sample(45,60,category:"SWE"), sample(60,75,idle:150)])
        XCTAssertEqual(result.stretches.count, 5)
        XCTAssertTrue(result.stretches.last!.idle)
        XCTAssertFalse(result.stretches.last!.active)
        XCTAssertTrue(result.gaps.isEmpty)
    }
    func testTenMinuteMaximumSplitsLongRunsWithoutDroppingSeconds() {
        let result = ScreenStretch.segment([sample(0, 1500)])
        XCTAssertEqual(result.stretches.map(\.seconds), [600,600,300])
        XCTAssertEqual(result.tasks.first?.seconds, 1500)
    }
    func testSameTaskMergesDisjointIntervalsWithoutCountingGaps() {
        let result = ScreenStretch.segment([sample(0,15),sample(15,30),sample(180,195,title:"same task another title")])
        XCTAssertEqual(result.stretches.count, 2)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].seconds, 45)
        XCTAssertEqual(result.tasks[0].intervals.count, 2)
        XCTAssertEqual(result.gaps.first?.end.timeIntervalSince(result.gaps.first!.start), 150)
    }
    func testOverlappingSamplesAreClippedAndDuplicatesCannotDoubleCount() {
        let result = ScreenStretch.segment([sample(0,15), sample(10,25),sample(10,25)])
        XCTAssertEqual(result.tasks.first?.seconds, 25)
        XCTAssertTrue(result.gaps.isEmpty)
    }
    func testDifferentTasksNeverMergeEvenInSameWindow() {
        let result = ScreenStretch.segment([sample(0,15,task:"problem1"),sample(15,30,task:"problem2")])
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.stretches.count, 2)
    }
}
