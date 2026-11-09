import XCTest
@testable import FocusCore

final class DayWhyTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private let focus: Set<String> = ["Math", "SWE", "AI"]

    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    /// A usual day, all of it logged: sleep to 8, AI 9–12 and 13–16, Admin, Leisure 20–23.
    private func usual(_ d: Int) -> [DayStory.Tracked] {
        [.init(start: at(d - 1, 23), end: at(d, 8), label: "Sleep"),
         .init(start: at(d, 8), end: at(d, 9), label: "Meals"),
         .init(start: at(d, 9), end: at(d, 12), label: "AI"),
         .init(start: at(d, 12), end: at(d, 13), label: "Meals"),
         .init(start: at(d, 13), end: at(d, 16), label: "AI"),
         .init(start: at(d, 16), end: at(d, 20), label: "Admin"),
         .init(start: at(d, 20), end: at(d, 23), label: "Leisure")]
    }

    private var history: [DayStory.Tracked] { (1...10).flatMap { usual($0) } }

    func testALightDayNamesTheLateStartTheLeisureAndWhatWasOnScreen() {
        let wednesday: [DayStory.Tracked] = [
            .init(start: at(10, 23), end: at(11, 11, 30), label: "Sleep"),
            .init(start: at(11, 12), end: at(11, 16), label: "Leisure"),
            .init(start: at(11, 16), end: at(11, 17), label: "AI"),
        ]
        let windows = [
            DayWhy.Window(start: at(11, 12), end: at(11, 14), app: "Google Chrome", title: "Some video - YouTube", category: "Leisure"),
            DayWhy.Window(start: at(11, 14), end: at(11, 15), app: "Google Chrome", title: "(17) Home / X", category: "Leisure"),
        ]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + wednesday, focus: focus, goalMinutes: 240,
                              windows: windows, calendar: calendar)
        XCTAssertTrue(r.light)
        XCTAssertEqual(r.focusMinutes, 60)
        XCTAssertEqual(r.usualMinutes, 360)
        XCTAssertEqual(r.comparedDays, 10)
        let leisure = r.reasons.first { $0.kind == .category && $0.category == "Leisure" }
        XCTAssertEqual(leisure?.title, "Leisure: 4h")
        XCTAssertEqual(leisure?.detail, "About 3h on an average day. Apps and sites: YouTube 2h, X 1h.")
        let late = r.reasons.first { $0.kind == .lateStart }
        XCTAssertEqual(late?.title, "Focus started at 4 PM")
        XCTAssertEqual(late?.detail, "Usually around 9 AM. You woke at 11:30 AM, usually 8 AM.")
        XCTAssertEqual(r.reasons.first { $0.kind == .sleep }?.title, "Slept 12h 30m the night before")
        XCTAssertEqual(r.reasons.first { $0.kind == .sleep }?.detail, "Usually 9h. 11h 30m of it after midnight.")
        XCTAssertEqual(r.reasons.map(\.kind), [.lateStart, .sleep, .category])
    }

    func testUntrackedTimeAwayFromTheMacSaysSo() {
        let day: [DayStory.Tracked] = usual(11).filter { $0.start != at(11, 13) }
            + [.init(start: at(11, 15, 30), end: at(11, 16), label: "AI")]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + day, focus: focus, goalMinutes: 300,
                              away: [DateInterval(start: at(11, 13), end: at(11, 15, 30))], calendar: calendar)
        let gap = r.reasons.first { $0.kind == .untracked }
        XCTAssertEqual(gap?.title, "Nothing logged for 2h 30m")
        XCTAssertEqual(gap?.ranges, [DateInterval(start: at(11, 13), end: at(11, 15, 30))])
        XCTAssertTrue(gap?.detail?.hasSuffix("You were away from your Mac for most of it.") == true)
    }

    func testShortPiecesAndDriftDuringFocus() {
        var day: [DayStory.Tracked] = [.init(start: at(10, 23), end: at(11, 8), label: "Sleep")]
        for h in 9..<15 { day.append(.init(start: at(11, h), end: at(11, h, 20), label: "AI")) }
        for h in 9..<15 { day.append(.init(start: at(11, h, 20), end: at(11, h + 1), label: "Leisure")) }
        let screen = [DayStory.Screen(start: at(11, 9), end: at(11, 9, 20), category: "Leisure")]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + day, focus: focus, goalMinutes: 300,
                              screen: screen, calendar: calendar)
        XCTAssertEqual(r.reasons.first { $0.kind == .fragmented }?.detail,
                       "Longest stretch 20m, usually 3h. 12 blocks logged, usually 6.")
        XCTAssertEqual(r.reasons.first { $0.kind == .drift }?.title, "During focus, the screen showed Leisure for 20m")
    }

    func testAGoodDayIsntLightAndTodayNeverIs() {
        let good = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + usual(11), focus: focus,
                                 goalMinutes: 240, calendar: calendar)
        XCTAssertFalse(good.light)
        XCTAssertTrue(good.reasons.isEmpty)
        let today = DayWhy.report(day: at(11, 12), now: at(11, 10), tracked: history + usual(11), focus: focus,
                                  goalMinutes: 240, calendar: calendar)
        XCTAssertFalse(today.light)
    }

    /// Class on four days in ten has a median of zero; "usually none" read wrong on 11/4.
    func testCategoriesCompareWithAnAverageDay() {
        let classes = [2, 3, 5, 6].map { d in DayStory.Tracked(start: at(d, 16), end: at(d, 18), label: "Class") }
        let day = usual(11).filter { $0.start != at(11, 13) } + [.init(start: at(11, 13), end: at(11, 16), label: "Class")]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + classes + day, focus: focus,
                              goalMinutes: 360, calendar: calendar)
        XCTAssertEqual(r.reasons.first { $0.category == "Class" }?.detail, "About 48m on an average day.")
    }

    /// 11/4: 2h 52m logged as Exercise while the Mac showed Leisure.
    func testABlockTheScreenSawAsSomethingElseSaysSo() {
        let day = usual(11).filter { $0.start != at(11, 13) } + [.init(start: at(11, 13), end: at(11, 16), label: "Exercise")]
        let screen = [DayStory.Screen(start: at(11, 13, 10), end: at(11, 13, 40), category: "Leisure")]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: history + day, focus: focus, goalMinutes: 360,
                              screen: screen, calendar: calendar)
        XCTAssertEqual(r.reasons.first { $0.category == "Exercise" }?.detail,
                       "Usually almost none. The screen showed Leisure for 30m of it.")
    }

    func testWithoutEnoughHistoryItListsTheBigNonFocusBlocks() {
        let day: [DayStory.Tracked] = [.init(start: at(11, 10), end: at(11, 14), label: "Leisure"),
                                       .init(start: at(11, 14), end: at(11, 15), label: "AI")]
        let r = DayWhy.report(day: at(11, 12), now: at(12, 9), tracked: day, focus: focus, goalMinutes: 240, calendar: calendar)
        XCTAssertNil(r.usualMinutes)
        XCTAssertEqual(r.reasons.map(\.title), ["Leisure: 4h"])
        XCTAssertNil(r.reasons.first?.detail)
    }

    func testPlacesNameTheSiteForBrowsersAndTheAppOtherwise() {
        func w(_ app: String, _ title: String) -> DayWhy.Window {
            DayWhy.Window(start: at(1, 1), end: at(1, 2), app: app, title: title, category: nil)
        }
        XCTAssertEqual(DayWhy.place(w("Google Chrome", "Opinion | Karp and Germany - The New York Times")), "The New York Times")
        XCTAssertEqual(DayWhy.place(w("Google Chrome", "Feed | LinkedIn")), "LinkedIn")
        XCTAssertEqual(DayWhy.place(w("Messages", "Sam")), "Messages")
        XCTAssertEqual(DayWhy.place(w("Safari", "Some page title with no site")), "Safari")
    }

    func testDominantScreenNeedsHalfTheStretch() {
        let screen = [DayStory.Screen(start: at(11, 21), end: at(11, 21, 40), category: "Leisure"),
                      DayStory.Screen(start: at(11, 21, 40), end: at(11, 21, 50), category: "AI")]
        XCTAssertEqual(DayStory.dominantScreen(screen, from: at(11, 21), to: at(11, 22)), "Leisure")
        XCTAssertNil(DayStory.dominantScreen(screen, from: at(11, 20), to: at(11, 22)))
    }
}
