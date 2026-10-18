import XCTest
@testable import FocusCore

final class LeetCodePracticeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_300_000)

    func testOnlyExactRegularActiveProblemURLsIdentifyAnAttempt() {
        func slug(_ value: String?, privacy: ScreenJournal.Privacy = .regular, active: Bool = true) -> String? {
            LeetCodePracticeEvidence.slug(url: value, privacy: privacy, active: active)
        }
        XCTAssertEqual(slug("https://leetcode.com/problems/two-sum/description/?envType=daily-question"), "two-sum")
        XCTAssertEqual(slug("https://www.leetcode.com/problems/two-sum/submissions/123/"), "two-sum")
        for url in ["https://leetcode.com/problemset/", "https://leetcode.com.evil.test/problems/two-sum/", "https://evil.test/?url=https://leetcode.com/problems/two-sum/", "http://leetcode.com/problems/two-sum/", "https://user@leetcode.com/problems/two-sum/", "https://leetcode.com:443/problems/two-sum/", "https://leetcode.com/problems/BadSlug/"] {
            XCTAssertNil(slug(url), url)
        }
        XCTAssertNil(slug("https://leetcode.com/problems/two-sum/", privacy: .unknown))
        XCTAssertNil(slug("https://leetcode.com/problems/two-sum/", privacy: .incognito))
        XCTAssertNil(slug("https://leetcode.com/problems/two-sum/", active: false))
        XCTAssertNil(slug(nil))
    }

    func testElapsedTimeExcludesPauseSleepAndRelaunchGap() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        state.update(at: start, tracking: true)
        state.update(at: start.addingTimeInterval(3), tracking: false)
        state.update(at: start.addingTimeInterval(600), tracking: true)
        state.update(at: start.addingTimeInterval(602), tracking: true)
        state.update(at: start.addingTimeInterval(3600), tracking: true)
        XCTAssertEqual(state.active?.seconds, 5)
        var restored = try JSONDecoder().decode(LeetCodePracticeState.self, from: JSONEncoder().encode(state))
        restored.restore()
        restored.update(at: start.addingTimeInterval(7200), tracking: true)
        restored.update(at: start.addingTimeInterval(7202), tracking: false)
        XCTAssertEqual(restored.active?.seconds, 7)
    }

    func testSwitchingProblemsPreservesAndResumesSeparateDrafts() {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        let firstID = state.activeID
        state.update(at: start, tracking: true)
        state.select(slug: "valid-parentheses", title: "Valid Parentheses", at: start.addingTimeInterval(4))
        state.update(at: start.addingTimeInterval(4), tracking: true)
        state.select(slug: "two-sum", title: "Two Sum", at: start.addingTimeInterval(7))
        state.update(at: start.addingTimeInterval(7), tracking: true)
        state.update(at: start.addingTimeInterval(9), tracking: false)
        XCTAssertEqual(state.activeID, firstID)
        XCTAssertEqual(state.active?.seconds, 6)
        XCTAssertEqual(state.sessions.first { $0.slug == "valid-parentheses" }?.seconds, 3)
        XCTAssertEqual(state.sessions.count, 2)
    }

    func testDoneFreezesTimeAndSuppressesRepeatedAutomaticCapture() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        state.update(at: start, tracking: true)
        let session = try XCTUnwrap(state.finish(at: start.addingTimeInterval(4)))
        state.update(at: start.addingTimeInterval(5), tracking: true)
        XCTAssertNil(state.active)
        XCTAssertEqual(session.seconds, 4)
        XCTAssertFalse(state.select(slug: "two-sum", title: "Two Sum", at: start.addingTimeInterval(6), automatic: true))
        XCTAssertEqual(state.sessions.count, 1)
        state.resume(id: session.id, at: start.addingTimeInterval(8))
        state.update(at: start.addingTimeInterval(8), tracking: true)
        state.update(at: start.addingTimeInterval(10), tracking: false)
        XCTAssertEqual(state.active?.seconds, 6)
    }

    func testUnsolvedPracticeKeepsDetailsAndDoesNotBecomeASolve() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        state.update(at: start, tracking: true)
        let session = try XCTUnwrap(state.finish(at: start.addingTimeInterval(3)))
        state.complete(id: session.id, solved: false, confidence: .struggled, usedHelp: true, notes: "Review hash lookup", title: "Two Sum", difficulty: .easy, categories: ["Arrays & Hashing"], minutes: 1)
        let restored = try JSONDecoder().decode(LeetCodePracticeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.sessions.first?.outcome, .unsolved)
        XCTAssertEqual(restored.sessions.first?.notes, "Review hash lookup")
        XCTAssertEqual(restored.sessions.first?.categories, ["Arrays & Hashing"])
        XCTAssertEqual(restored.sessions.first?.seconds, 3)
        XCTAssertEqual(restored.sessions.first?.loggedMinutes, 1)
        XCTAssertEqual(restored.sessions.filter { $0.outcome == .solved }.count, 0)
    }

    func testPreparingAnotherDraftDoesNotEndCurrentProblem() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        let first = try XCTUnwrap(state.activeID)
        state.select(slug: "valid-parentheses", title: "Valid Parentheses", at: start)
        let current = state.activeID
        let draft = state.prepareLog(id: first, at: start.addingTimeInterval(1))
        XCTAssertEqual(draft?.id, first)
        XCTAssertNotNil(draft?.finishedAt)
        XCTAssertEqual(state.activeID, current)
    }

    func testRepeatedManualSelectionDoesNotResetTheClock() {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        state.update(at: start, tracking: true)
        XCTAssertTrue(state.select(slug: "two-sum", title: "Two Sum", at: start.addingTimeInterval(2)))
        state.update(at: start.addingTimeInterval(3), tracking: false)
        XCTAssertEqual(state.active?.seconds, 3)
        XCTAssertEqual(state.sessions.count, 1)
    }
    func testCompletionIsIdempotentAndNeverRewritesASavedOutcome() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        let session = try XCTUnwrap(state.finish(at: start))
        state.complete(id: session.id, solved: true, confidence: .solid, usedHelp: false, notes: "Hash map", title: "Two Sum")
        state.complete(id: session.id, solved: false, confidence: .struggled, usedHelp: true, notes: "Duplicate save", title: "Changed")
        XCTAssertEqual(state.sessions.first?.outcome, .solved)
        XCTAssertEqual(state.sessions.first?.notes, "Hash map")
        XCTAssertEqual(state.sessions.count, 1)
    }

    func testPartialDetailsSurviveDeferringTheLog() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        let session = try XCTUnwrap(state.finish(at: start))
        let details = LeetCodePracticeState.Details(title: "Two Sum", difficulty: .easy,
            categories: ["Arrays & Hashing"], solved: nil, confidence: nil,
            minutes: nil, usedHelp: true, notes: "Remember complements")
        state.keepDetails(id: session.id, details: details)
        let restored = try JSONDecoder().decode(LeetCodePracticeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.sessions.first?.draftDetails, details)
        XCTAssertEqual(restored.sessions.first?.outcome, .draft)
        XCTAssertNil(restored.activeID)
        XCTAssertEqual(restored.sessions.count, 1)
    }

    func testReturningAfterNavigationStartsFreshWorkWithoutAutoSolving() throws {
        var state = LeetCodePracticeState()
        state.select(slug: "two-sum", title: "Two Sum", at: start)
        let first = try XCTUnwrap(state.finish(at: start))
        state.observePage(slug: "two-sum")
        XCTAssertFalse(state.select(slug: "two-sum", title: "Two Sum", at: start, automatic: true))
        state.observePage(slug: "valid-parentheses")
        XCTAssertTrue(state.select(slug: "valid-parentheses", title: "Valid Parentheses", at: start, automatic: true))
        state.observePage(slug: "two-sum")
        XCTAssertTrue(state.select(slug: "two-sum", title: "Two Sum", at: start, automatic: true))
        XCTAssertNotEqual(state.activeID, first.id)
        XCTAssertEqual(state.active?.slug, "two-sum")
        XCTAssertEqual(state.sessions.filter { $0.outcome == .solved }.count, 0)
        XCTAssertEqual(state.sessions.first { $0.id == first.id }?.seconds, 0)
    }

}
