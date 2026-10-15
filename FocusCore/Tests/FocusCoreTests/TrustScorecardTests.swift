import XCTest
@testable import FocusCore

final class TrustScorecardTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: Double) -> Date { start.addingTimeInterval(s) }

    func testModesNeverMixAndUnansweredDoesNotMeanWrong() {
        let cards: [TrustScorecard.Card] = [
            .init(shown: at(100), since: at(40), answer: nil, automatic: false, mode: .normal),
            .init(shown: at(200), since: at(100), answer: "switched to Math", automatic: false, mode: .test),
            .init(shown: at(300), since: at(200), answer: "kept SWE", automatic: false, mode: .unknown)]
        let s = TrustScorecard.score(mode: .normal, observations: [], tracking: [],
                                    checks: [.init(right: true, mode: .test), .init(right: false, mode: .normal)],
                                    cards: cards, from: start, to: at(2000), now: at(2000))
        XCTAssertEqual(s.checked, 1); XCTAssertEqual(s.right, 0)
        XCTAssertEqual(s.ignored, 1); XCTAssertEqual(s.switched, 0)
        XCTAssertEqual(s.medianDelay, 60)
    }

    func testAgreementClipsAndExcludesAmbiguousOverlapsWithoutDoubleCounting() {
        let spans: [TrustScorecard.Observation] = [
            .init(start: at(-20), end: at(100), category: "Math", mode: .normal),
            .init(start: at(0), end: at(100), category: "Math", mode: .normal)]
        let rows = [WorkSession(startTime: start, durationMinutes: 2, type: .work, label: "Math"),
                    WorkSession(startTime: at(50), durationMinutes: 1, type: .work, label: "SWE")]
        let s = TrustScorecard.score(mode: .normal, observations: spans, tracking: rows, checks: [], cards: [],
                                     from: start, to: at(200), now: at(80))
        XCTAssertEqual(s.comparedSeconds, 50); XCTAssertEqual(s.agreeingSeconds, 50)
    }

    func testAutoUndoHasItsOwnDenominatorAndOpenCardsArePending() {
        let cards: [TrustScorecard.Card] = [
            .init(shown: at(0), since: at(-45), answer: "undid, kept SWE", automatic: true, mode: .normal),
            .init(shown: at(10), since: nil, answer: nil, automatic: true, mode: .normal),
            .init(shown: at(100), since: at(90), answer: nil, automatic: false, mode: .normal),
            .init(shown: at(100), since: nil, answer: nil, automatic: true, mode: .normal)]
        let s = TrustScorecard.score(mode: .normal, observations: [], tracking: [], checks: [], cards: cards,
                                     from: start, to: at(200), now: at(120))
        XCTAssertEqual(s.automatic, 2); XCTAssertEqual(s.undone, 1)
        XCTAssertEqual(s.pending, 2); XCTAssertEqual(s.ignored, 0)
        XCTAssertEqual(s.medianDelay, 27.5)
    }
}
