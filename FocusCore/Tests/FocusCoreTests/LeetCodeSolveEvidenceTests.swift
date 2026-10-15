import XCTest
@testable import FocusCore

final class LeetCodeSolveEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private func row(url: String = "https://leetcode.com/problems/two-sum/submissions/123456/",text: String = "Accepted\nRuntime\n0 ms\nMemory",privacy: ScreenJournal.Privacy = .regular,offset: Double = 0) -> ScreenJournal.Row {
        .init(at:now.addingTimeInterval(offset),end:now.addingTimeInterval(offset+15),app:"Chrome",bundle:"com.google.Chrome",windowID:"1",title:"Two Sum - LeetCode",url:url,category:"SWE",trackedCategory:"SWE",active:true,idleSeconds:0,privacy:privacy,evidenceImageID:UUID(),text:text)
    }
    func testAcceptedSubmissionBoundToOfficialProblemURLCreatesOnlyCandidate() throws {
        let row = row()
        let candidate = try XCTUnwrap(LeetCodeSolveEvidence.candidate(row:row,text:row.text!))
        XCTAssertEqual(candidate.slug,"two-sum")
        XCTAssertEqual(candidate.submissionID,"123456")
        XCTAssertEqual(candidate.observedAt,now)
        XCTAssertEqual(candidate.journalRowID,row.id)
        let another = self.row(offset:30)
        XCTAssertEqual(candidate.dailyKey,LeetCodeSolveEvidence.candidate(row:another,text:another.text!)?.dailyKey)
    }
    func testUnboundAcceptedCountsWrongDomainAndPrivateFramesAreIgnored() {
        for url in ["https://leetcode.com/problems/two-sum/", "https://leetcode.com/submissions/detail/123456/", "https://leetcode.com.evil.test/problems/two-sum/submissions/123456/", "http://leetcode.com/problems/two-sum/submissions/123456/"] {
            let row = row(url:url)
            XCTAssertNil(LeetCodeSolveEvidence.candidate(row:row,text:row.text!))
        }
        for text in ["Accepted 200K\nRuntime", "Not Accepted\nRuntime", "Accepted\nExample output"] {
            let row = row(text:text)
            XCTAssertNil(LeetCodeSolveEvidence.candidate(row:row,text:text))
        }
        for privacy in [ScreenJournal.Privacy.unknown,.incognito,.notBrowser] {
            let row = row(privacy:privacy)
            XCTAssertNil(LeetCodeSolveEvidence.candidate(row:row,text:row.text!))
        }
        let row = row()
        XCTAssertNil(LeetCodeSolveEvidence.candidate(row:row,text:"altered text"))
    }
    func testSolveTimeOnlyComesFromMatchingActualStopwatchAtObservation() {
        XCTAssertEqual(LeetCodeSolveEvidence.stopwatchMinutes(slug:"two-sum",activeSlug:"two-sum",startedAt:now.addingTimeInterval(-600),observedAt:now),10)
        XCTAssertNil(LeetCodeSolveEvidence.stopwatchMinutes(slug:"two-sum",activeSlug:nil,startedAt:nil,observedAt:now))
        XCTAssertNil(LeetCodeSolveEvidence.stopwatchMinutes(slug:"two-sum",activeSlug:"other",startedAt:now.addingTimeInterval(-600),observedAt:now))
        XCTAssertNil(LeetCodeSolveEvidence.stopwatchMinutes(slug:"two-sum",activeSlug:"two-sum",startedAt:now.addingTimeInterval(60),observedAt:now))
    }
}
