import XCTest
@testable import FocusCore

final class OvernightSleepTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Hours from 10/17 midnight; 23.5 = 11:30 PM on the 17th, 34 = 10 AM on the 18th.
    private func t(_ h: Double) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 17))!.addingTimeInterval(h * 3600)
    }

    private func span(_ a: Double, _ b: Double) -> DateInterval { DateInterval(start: t(a), end: t(b)) }

    func testRecruitingLeftRunningOvernightBecomesSleepForTheAwayStretch() {
        let fixes = OvernightSleep.fixes(
            away: [span(23.85, 34.95)], activity: [],
            blocks: [.init(start: t(23.5), end: t(35), label: "Recruiting", running: true)],
            now: t(35), calendar: cal)
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes[0].start, t(23.85))
        XCTAssertEqual(fixes[0].end, t(34.95))
        XCTAssertEqual(fixes[0].label, "Recruiting")
        XCTAssertTrue(fixes[0].running)
    }

    func testAfternoonAwayIsNotANight() {
        // 10/17: Leisure 2:08 PM – 11:29 PM with the display off the whole time.
        let fixes = OvernightSleep.fixes(
            away: [span(14.1, 23.5)], activity: [],
            blocks: [.init(start: t(14.1), end: t(23.5), label: "Leisure")], now: t(35), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testSleepBlocksAndGapsAreLeftAlone() {
        let fixes = OvernightSleep.fixes(
            away: [span(23.85, 34.95)], activity: [],
            blocks: [.init(start: t(23.5), end: t(23.52), label: "Recruiting"),
                     .init(start: t(23.52), end: t(34.1), label: "Sleep")],
            now: t(35), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testPhoneUseCutsTheNightAndBriefChecksDont() {
        // Scrolling the phone in bed until 1:30, a 2-minute time check at 4.
        let fixes = OvernightSleep.fixes(
            away: [span(23, 33)],
            activity: [span(23.2, 25.5), span(28, 28.03)],
            blocks: [.init(start: t(22), end: t(33), label: "Leisure")], now: t(34), calendar: cal)
        XCTAssertEqual(fixes.map(\.start), [t(25.5)])
        XCTAssertEqual(fixes.first?.end, t(33))
    }

    func testBackBeforeFiveIsNotANight() {
        let fixes = OvernightSleep.fixes(
            away: [span(22, 28.5)], activity: [],
            blocks: [.init(start: t(21), end: t(29), label: "Social")], now: t(30), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testTripLongerThanSixteenHoursIsLeftForTheCard() {
        let fixes = OvernightSleep.fixes(
            away: [span(18, 36)], activity: [],
            blocks: [.init(start: t(17), end: t(37), label: "Leisure")], now: t(37), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testEveryNonSleepBlockInTheNightIsFixedAndNothingPastNow() {
        // Leisure until 11:10, a break picked as you left at 11:02 still running.
        let fixes = OvernightSleep.fixes(
            away: [span(23, 33)], activity: [],
            blocks: [.init(start: t(22), end: t(23.17), label: "Leisure"),
                     .init(start: t(23.03), end: t(40), label: nil, running: true)],
            now: t(32), calendar: cal)
        XCTAssertEqual(fixes.count, 2)
        guard fixes.count == 2 else { return }
        XCTAssertEqual(fixes[0].label, "Leisure")
        XCTAssertEqual(fixes[0].end, t(23.17))
        XCTAssertNil(fixes[1].label)
        XCTAssertEqual(fixes[1].end, t(32))
        XCTAssertEqual(Set(fixes.map(\.night.start)), [t(23)])
    }

    func testABlockPickedDuringTheNightEndsItAndIsLeftAlone() {
        // 10/18: Recruiting from 11:29 PM, Meals picked on the phone at 10:03,
        // Mac away until 10:57. Recruiting (split at midnight) → Sleep to 10:03.
        let fixes = OvernightSleep.fixes(
            away: [span(23.85, 34.95)], activity: [],
            blocks: [.init(start: t(23.5), end: t(24), label: "Recruiting"),
                     .init(start: t(24), end: t(34.05), label: "Recruiting"),
                     .init(start: t(34.05), end: t(35.1), label: "Meals")],
            now: t(35.2), calendar: cal)
        XCTAssertEqual(fixes.map(\.label), ["Recruiting", "Recruiting"])
        XCTAssertEqual(fixes.first?.start, t(23.85))
        XCTAssertEqual(fixes.last?.end, t(34.05))
    }

    func testSwitchingAtTwoAMMeansYouWereUp() {
        let fixes = OvernightSleep.fixes(
            away: [span(23, 33)], activity: [],
            blocks: [.init(start: t(22), end: t(26), label: "Recruiting"),
                     .init(start: t(26), end: t(33.5), label: "Leisure")],
            now: t(34), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testSleepPickedAtMidnightKeepsTheEveningBlock() {
        // 10/16: SWE from 10:37 PM, Mac away from 10:54, Sleep picked at midnight.
        let fixes = OvernightSleep.fixes(
            away: [span(22.9, 32.5)], activity: [],
            blocks: [.init(start: t(22.6), end: t(24), label: "SWE"),
                     .init(start: t(24), end: t(32.7), label: "Sleep")],
            now: t(33), calendar: cal)
        XCTAssertTrue(fixes.isEmpty)
    }

    func testBlockPickedAsYouLeftCounts() {
        let fixes = OvernightSleep.fixes(
            away: [span(23, 33)], activity: [],
            blocks: [.init(start: t(23.02), end: t(34), label: "Leisure", running: true)],
            now: t(34), calendar: cal)
        XCTAssertEqual(fixes.first?.start, t(23.02))
    }

    func testLateBedtimeStillCounts() {
        // Bed at 3:30 AM, back at 11.
        XCTAssertEqual(OvernightSleep.nights(away: [span(27.5, 35)], activity: [], calendar: cal).count, 1)
    }
}
