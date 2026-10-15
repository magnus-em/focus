import XCTest
@testable import FocusCore

final class WhereWasITests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ h: Int, _ m: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: h, minute: m))!
    }
    private func rec(_ h: Int, _ m: Int, tracked: String, topic: String, activity: String = "solving",
                     questions: [String] = [], privacy: ScreenJournal.Privacy = .notBrowser, url: String? = nil) -> CoachEpisode.Record {
        let row = ScreenJournal.Row(at: at(h, m), end: at(h, m).addingTimeInterval(15), app: "ChatGPT", bundle: "com.openai.chat",
                                    windowID: "1:2", title: "t", url: url, category: tracked, trackedCategory: tracked,
                                    active: true, idleSeconds: 0, privacy: privacy, evidenceImageID: nil, text: "x")
        let u = CoachEpisode.Understanding(topic: topic, course: tracked == "Math" ? "MATH 244" : nil, activity: activity,
                                           concepts: [], summary: "", notes: [], questions: questions, transcription: nil,
                                           diagram: false, unreadable: false, struggle: nil, confidence: .high)
        return CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
    }

    func testLatestEpisodeOfTheRunningCategory() {
        let eps = [rec(12, 20, tracked: "Math", topic: "Posets"),
                   rec(12, 52, tracked: "Math", topic: "Inclusion–exclusion", questions: ["Why (b) and not (c)?"]),
                   rec(13, 10, tracked: "SWE", topic: "Syscalls")]
        let line = WhereWasI.line(eps, running: "Math", now: at(14, 30), calendar: calendar)
        XCTAssertEqual(line?.text, "Last time on MATH 244 (12:52 PM): Inclusion–exclusion; you asked: Why (b) and not (c)?")
        XCTAssertNil(line?.url)
    }

    func testNothingWhenStillAtItOrOnlyAdminOrPrivate() {
        XCTAssertNil(WhereWasI.line([rec(14, 20, tracked: "Math", topic: "Posets")], running: "Math", now: at(14, 30), calendar: calendar))
        XCTAssertNil(WhereWasI.line([rec(12, 0, tracked: "Math", topic: "Focus app", activity: "admin")], running: "Math", now: at(14, 30), calendar: calendar))
        XCTAssertNil(WhereWasI.line([rec(12, 0, tracked: "Math", topic: "x", privacy: .unknown)], running: "Math", now: at(14, 30), calendar: calendar))
        XCTAssertNil(WhereWasI.line([], running: "Math", now: at(14, 30), calendar: calendar))
    }

    func testReopensOnlyConfirmedHTTPSAddresses() {
        let ok = rec(12, 0, tracked: "SWE", topic: "Two Sum", privacy: .regular, url: "https://leetcode.com/problems/two-sum/")
        XCTAssertEqual(WhereWasI.line([ok], running: "SWE", now: at(14, 0), calendar: calendar)?.url?.host, "leetcode.com")
        let file = rec(12, 0, tracked: "SWE", topic: "Notes", privacy: .regular, url: "file:///Users/x/notes.pdf")
        XCTAssertNil(WhereWasI.line([file], running: "SWE", now: at(14, 0), calendar: calendar)?.url)
    }
}
