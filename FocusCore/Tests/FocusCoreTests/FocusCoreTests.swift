import XCTest
@testable import FocusCore

final class RecallSchedulerTests: XCTestCase {
    func testLadderClimbsOneRungOnGot() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 1, grade: .got, hinted: false), 3)
        XCTAssertEqual(RecallScheduler.nextInterval(current: 3, grade: .got, hinted: false), 7)
    }

    func testFluentSkipsARung() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 3, grade: .fluent, hinted: false), 14)
    }

    func testHintCapsAtPartialAndDropsARung() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 7, grade: .fluent, hinted: true), 3)
    }

    func testForgotRestarts() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 60, grade: .forgot, hinted: false), 1)
    }

    func testPastTheLadderDoublesUpToAYear() {
        XCTAssertEqual(RecallScheduler.nextInterval(current: 240, grade: .got, hinted: false), 365)
    }

    func testDueDateIsStartOfTheDayIntervalLater() {
        let cal = Calendar(identifier: .gregorian)
        let from = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 22))!
        let due = RecallScheduler.dueDate(from: from, interval: 3, calendar: cal)
        XCTAssertEqual(due, cal.date(from: DateComponents(year: 2026, month: 10, day: 16)))
    }
}

final class TimerDisplayTests: XCTestCase {
    let day: TimeInterval = FocusCategories.openEndedSeconds

    func testCountdownShowsTimeLeft() {
        XCTAssertEqual(FocusCategories.timeString(total: 25 * 60, remaining: 10 * 60 + 5), "10:05")
    }

    func testOvertimeShowsElapsedAndOvertime() {
        let total = day + 60 * 60, remaining = total - 75 * 60
        XCTAssertEqual(FocusCategories.timeString(total: total, remaining: remaining), "1:15:00")
        XCTAssertEqual(FocusCategories.overtime(total: total, remaining: remaining), 15 * 60)
    }

    func testLifeBlockHasNoOvertimeAndAFullRing() {
        XCTAssertNil(FocusCategories.overtime(total: day, remaining: day - 600))
        XCTAssertEqual(FocusCategories.progress(total: day, remaining: day - 600), 1)
        XCTAssertEqual(FocusCategories.countdown(total: day), 0)
    }
}

final class DurationTextTests: XCTestCase {
    func testNoZeroMinuteTails() {
        XCTAssertEqual(durationText(minutes: 420), "7h")
        XCTAssertEqual(durationText(minutes: 425.9), "7h 5m")
        XCTAssertEqual(durationText(minutes: 45), "45m")
        XCTAssertEqual(durationText(minutes: 0.4), "0m")
    }
}

final class DailyFocusCategoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))! }

    func testAggregatesRepeatedFocusAndLiveWorkWithoutLifeOrBreaks() {
        let sessions = [
            WorkSession(startTime: day, durationMinutes: 1, type: .work, label: "Math"),
            WorkSession(startTime: day.addingTimeInterval(120), durationMinutes: 1.5, type: .work, label: "Math"),
            WorkSession(startTime: day, durationMinutes: 30, type: .work, label: "Admin"),
            WorkSession(startTime: day, durationMinutes: 20, type: .shortBreak, label: "Math"),
            WorkSession(startTime: day, durationMinutes: 2, type: .work, label: "AI")
        ]
        let live = WorkSession(startTime: day.addingTimeInterval(600), durationMinutes: 3, type: .work, label: "SWE")
        let totals = FocusStats.focusCategoryMinutes(sessions, live: live, on: day,
                                                     through: day.addingTimeInterval(3600), lifeTags: ["Admin"], calendar: calendar)
        XCTAssertEqual(totals["Math"], 2.5)
        XCTAssertEqual(totals["SWE"], 3)
        XCTAssertNil(totals["Admin"])
        XCTAssertEqual(Set(totals.filter { $0.value > 2 }.keys), ["Math", "SWE"])
    }

    func testClipsMidnightSessionsAndIgnoresFutureTime() {
        let sessions = [
            WorkSession(startTime: day.addingTimeInterval(-900), durationMinutes: 45, type: .work, label: "Math"),
            WorkSession(startTime: day.addingTimeInterval(7200), durationMinutes: 60, type: .work, label: "SWE")
        ]
        let totals = FocusStats.focusCategoryMinutes(sessions, on: day, through: day.addingTimeInterval(600),
                                                     lifeTags: [], calendar: calendar)
        XCTAssertEqual(totals["Math"], 10)
        XCTAssertNil(totals["SWE"])
    }
}

final class TimeIntegrityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    private func block(_ label: String?, _ from: Double, _ to: Double) -> WorkSession {
        WorkSession(startTime: at(from), durationMinutes: to - from, type: label == nil ? .shortBreak : .work, label: label)
    }

    // 10/14: the iPad saved Class 12:17 → 3:10, the Mac the iPhone's Class 12:42 → 3:10.
    func testSameCategorySavedTwiceMergesToTheUnion() {
        let found = TimeIntegrity.overlaps(in: [block("Class", 0, 173.6), block("Class", 25, 173.5)],
                                           from: at(-60), to: at(300))
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].sameLabel)
        XCTAssertEqual(found[0].union.start, at(0))
        XCTAssertEqual(found[0].union.end, at(173.6))
    }

    // 10/13: SWE 9:13:47 for 48.8 min and a phantom Leisure from 9:13:57.
    func testDifferentCategoriesNeedTheUser() {
        let found = TimeIntegrity.overlaps(in: [block("SWE", 0, 48.8), block("Leisure", 0.17, 55.6)],
                                           from: at(-60), to: at(300))
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].sameLabel)
        XCTAssertEqual(found[0].start, at(0.17))
        XCTAssertEqual(found[0].end, at(48.8))
    }

    func testBackToBackAndSecondsOfRoundingArentOverlaps() {
        let rows = [block("Math", 0, 30), block("Admin", 30, 40), block("SWE", 39.5, 60)]
        XCTAssertTrue(TimeIntegrity.overlaps(in: rows, from: at(-60), to: at(300)).isEmpty)
    }

    func testOnlyBlocksTouchingTheWindowAndNewestFirst() {
        let rows = [block("Math", 0, 30), block(nil, 10, 20), block("SWE", 600, 700), block("AI", 650, 660)]
        let found = TimeIntegrity.overlaps(in: rows, from: at(-60), to: at(1000))
        XCTAssertEqual(found.map(\.second.label), ["AI", nil])
        XCTAssertTrue(TimeIntegrity.overlaps(in: rows, from: at(500), to: at(1000)).count == 1)
    }
}

final class RemoteStopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }

    // The iPad held Class from 12:17; the Mac stopped the iPhone's Class from 12:42.
    func testOursEndsWhereTheStoppedSessionBegan() {
        XCTAssertEqual(RemoteStop.end(mine: at(0), stoppedStart: at(25), stoppedAt: at(173), now: at(174)), at(25))
    }

    func testSameSessionEndsAtTheStopNotWhenWeHeard() {
        XCTAssertEqual(RemoteStop.end(mine: at(0), stoppedStart: at(0), stoppedAt: at(60), now: at(240)), at(60))
    }

    func testOlderPeersWithoutAStartStillCapAtTheStop() {
        XCTAssertEqual(RemoteStop.end(mine: at(0), stoppedStart: nil, stoppedAt: at(60), now: at(61)), at(60))
    }

    func testAPeerStoppingAnOlderSessionDoesntCutOurs() {
        XCTAssertEqual(RemoteStop.end(mine: at(30), stoppedStart: at(0), stoppedAt: at(60), now: at(61)), at(60))
    }

    // 10/13: after a relaunch, cutting at 00:19:45 saved 30 min (to the relaunch) instead of 9.
    func testDurationNeverExceedsTheWallClockSpan() {
        XCTAssertEqual(RemoteStop.duration(elapsed: 30 * 60, start: at(0), end: at(8.9)), 8.9 * 60, accuracy: 0.001)
        XCTAssertEqual(RemoteStop.duration(elapsed: 5 * 60, start: at(0), end: at(8.9)), 5 * 60)
    }
}

final class OverlapFixTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    private func block(_ label: String?, _ from: Double, _ to: Double) -> WorkSession {
        WorkSession(startTime: at(from), durationMinutes: to - from, type: label == nil ? .shortBreak : .work, label: label)
    }
    private func touched(_ edits: [OverlapEdit]) -> Set<UUID> {
        Set(edits.compactMap { e -> UUID? in
            switch e { case .setDuration(let id, _), .delete(let id): return id; case .insert: return nil }
        })
    }

    // Codex's case: Class A 0–120, Class B 30–60, Leisure C 90–100. Merging A/B leaves C alone.
    func testMergeTouchesOnlyThePair() {
        let a = block("Class", 0, 120), b = block("Class", 30, 60), c = block("Leisure", 90, 100)
        let o = TimeIntegrity.overlaps(in: [a, b, c], from: at(-1), to: at(200)).first { $0.second.id == b.id }!
        let edits = TimeIntegrity.merge(o)
        XCTAssertEqual(touched(edits), [a.id, b.id])
        guard case .setDuration(_, let m) = edits[0] else { return XCTFail() }
        XCTAssertEqual(m, 120, accuracy: 0.001)
    }

    func testPickingOneCutsOnlyTheOtherAndKeepsItsOutsideParts() {
        let swe = block("SWE", 0, 48.8), leisure = block("Leisure", 0.2, 55.6)
        let o = TimeIntegrity.overlaps(in: [swe, leisure], from: at(-1), to: at(100))[0]
        let keepSWE = TimeIntegrity.resolve(o, keep: swe.id)
        XCTAssertEqual(touched(keepSWE), [leisure.id])
        guard case .insert(let tail) = keepSWE.last else { return XCTFail() }
        XCTAssertEqual(tail.startTime, at(48.8))
        XCTAssertEqual(tail.label, "Leisure")
        let keepLeisure = TimeIntegrity.resolve(o, keep: leisure.id)
        XCTAssertEqual(touched(keepLeisure), [swe.id])
        guard case .setDuration(_, let m) = keepLeisure[0] else { return XCTFail() }
        XCTAssertEqual(m, 0.2, accuracy: 0.001)
    }
}

final class RemoteStopSaveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }

    // Codex: mine 12:42, a peer stops 12:17 while we slept: ours is newer, keep it.
    func testStaleDeviceKeepsANewerSessionWhenAnOlderOneStops() {
        XCTAssertEqual(RemoteStop.savedEnd(mine: at(25), stoppedStart: at(0), stoppedAt: at(173), now: at(200),
                                           stale: true, shared: true), at(173))
    }

    func testStaleSharedSessionSkipsWhenALaterOneStopped() {
        XCTAssertNil(RemoteStop.savedEnd(mine: at(0), stoppedStart: at(25), stoppedAt: at(173), now: at(200),
                                         stale: true, shared: true))
    }

    // 10/14 night: saving "up to the later start" stretched Math 5:22 → 6:24 to 10:44 PM via dedup.
    func testAwakeDeviceAlsoSkipsWhenALaterSessionStopped() {
        XCTAssertNil(RemoteStop.savedEnd(mine: at(0), stoppedStart: at(25), stoppedAt: at(173), now: at(174),
                                         stale: false, shared: true))
    }
}

final class BackdatedStopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }

    // Codex: Class from 13:00, "End Class at 13:40" clicked at 15:10. The idle
    // carries 13:40 as its end; a peer holding the same Class saves to 13:40.
    func testPeerSavesToTheBackdatedEndNotWhenItHeard() {
        XCTAssertEqual(RemoteStop.savedEnd(mine: at(0), stoppedStart: at(0), stoppedAt: at(40), now: at(130),
                                           stale: false, shared: true), at(40))
    }
}

final class WideOverlapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    private func block(_ label: String, _ from: Double, _ to: Double) -> WorkSession {
        WorkSession(startTime: at(from), durationMinutes: to - from, type: .work, label: label)
    }

    // 10/14: one Class block from 12:42 to 5:54 over the day's other blocks.
    func testOneBlockOverManyIsCountedAndRemovable() {
        let wide = block("Class", 0, 312)
        let rows = [wide, block("Leisure", 0, 58), block("Class", 18, 58), block("Admin", 150, 218), block("Math", 280, 342)]
        let found = TimeIntegrity.overlaps(in: rows, from: at(-1), to: at(400))
        XCTAssertEqual(TimeIntegrity.overlapCount(wide, in: found), 4)
        guard case .delete(let id) = TimeIntegrity.remove(wide).first else { return XCTFail() }
        XCTAssertEqual(id, wide.id)
    }
}

final class LogCorrectionTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private func t(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    func testTwelveHourTimesPickTheLatestPastOne() {
        let now = t(14, 15, 12)
        XCTAssertEqual(LogCorrection.resolve("1:40", now: now, calendar: cal), t(14, 13, 40))
        XCTAssertEqual(LogCorrection.resolve("13:00", now: now, calendar: cal), t(14, 13, 0))
        XCTAssertEqual(LogCorrection.resolve("now", now: now, calendar: cal), now)
        XCTAssertNil(LogCorrection.resolve("25:00", now: now, calendar: cal))
    }

    // Codex: an explicit am must survive ("1am" said at 3 PM is 1 AM, not 1 PM).
    func testExplicitMeridiemIsKept() {
        let now = t(14, 15, 12)
        XCTAssertEqual(LogCorrection.resolve("1:00am", now: now, calendar: cal), t(14, 1, 0))
        XCTAssertEqual(LogCorrection.resolve("9:00pm", now: t(14, 22, 0), calendar: cal), t(14, 21, 0))
        let blocks = LogCorrection.validate([LogCorrection.Raw(from: "1:00", to: "+20", category: "Class")],
                                            now: now, categories: ["Class"], calendar: cal)
        XCTAssertEqual(blocks, [LogCorrection.Block(start: t(14, 13, 0), end: t(14, 13, 20), category: "Class")])
    }

    func testLateTimesSaidAfterMidnightAreLastNight() {
        XCTAssertEqual(LogCorrection.resolve("23:30", now: t(15, 0, 10), calendar: cal), t(14, 23, 30))
    }

    // The 10/14 case: "I was in class 1–1:40, the rest was leisure", said at 3:12 PM.
    func testTheUsersSentenceBecomesTwoBlocks() {
        let raw = [LogCorrection.Raw(from: "13:00", to: "13:40", category: "Class"),
                   LogCorrection.Raw(from: "13:40", to: "now", category: "Leisure")]
        let blocks = LogCorrection.validate(raw, now: t(14, 15, 12), categories: ["Class", "Leisure"], calendar: cal)
        XCTAssertEqual(blocks, [LogCorrection.Block(start: t(14, 13, 0), end: t(14, 13, 40), category: "Class"),
                                LogCorrection.Block(start: t(14, 13, 40), end: t(14, 15, 12), category: "Leisure")])
    }

    func testNonsenseIsDropped() {
        let raw = [LogCorrection.Raw(from: "14:00", to: "13:00", category: "Math"),
                   LogCorrection.Raw(from: "10:00", to: "11:00", category: "Juggling"),
                   LogCorrection.Raw(from: "10:00", to: "11:00", category: "Break"),
                   LogCorrection.Raw(from: "10:30", to: "10:45", category: "Math")]
        let blocks = LogCorrection.validate(raw, now: t(14, 15, 0), categories: ["Math"], calendar: cal)
        XCTAssertEqual(blocks, [LogCorrection.Block(start: t(14, 10, 0), end: t(14, 11, 0), category: nil)])
    }
}

final class LogCorrectionParseTests: XCTestCase {
    private let cats = ["Quant", "SWE", "AI", "HW", "Class", "Meals", "Leisure", "Sleep", "Chores", "Exercise",
                        "Social", "Commute", "Admin", "Reading", "Math"]
    private func read(_ s: String) -> [String]? {
        LogCorrection.parse(s, categories: cats)?.map { "\($0.from)|\($0.to)|\($0.category)" }
    }

    func testCommonPhrasings() {
        XCTAssertEqual(read("I was in class 1-1:40, the rest was leisure"), ["1:00|1:40|Class", "||Leisure"])
        XCTAssertEqual(read("lunch from 12:20 to 12:50 then class until 1:40"), ["12:20|12:50|Meals", "|1:40|Class"])
        XCTAssertEqual(read("math since 2"), ["2:00|now|Math"])
        XCTAssertEqual(read("took a break 2:30 to 2:45"), ["2:30|2:45|Break"])
        XCTAssertEqual(read("gym 7am-8:15am then breakfast"), ["7:00am|8:15am|Exercise", "||Meals"])
        XCTAssertEqual(read("homework from 9pm"), ["9:00pm||HW"])
        XCTAssertEqual(read("i ate around 12:30 for half an hour"), ["12:30|+30|Meals"])
        XCTAssertEqual(read("leetcode at 9pm for 45 min"), ["9:00pm|+45|SWE"])
        // Codex: a length's number isn't a clock time.
        XCTAssertEqual(read("Class at 1 for 20 min"), ["1:00|+20|Class"])
    }

    func testFallsBackToTheModelWhenItCantRead() {
        XCTAssertNil(read("the usual stuff this afternoon"))
        XCTAssertNil(read("class then leisure"))
    }
}
