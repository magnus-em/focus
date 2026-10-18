import XCTest
@testable import FocusCore

final class ReadingPolicyTests: XCTestCase {
    func testEducationalLongFormStaysReading() {
        for (title, text) in [("Understanding entropy — an explainer", ""),
                              ("Chapter 2", "This book explains the history of science."),
                              ("Swift documentation", "Learn how actors work."),
                              ("An essay on philosophy", ""),
                              ("Research paper", "We study the evidence.")] {
            XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Preview", title: title, text: text).category, "Reading", title)
        }
    }

    func testCodingPracticeSitesUseLeetCodeOrSWE() {
        for (title, source) in [("Number of Orders in the Backlog - LeetCode", ScreenClassificationPolicy.Source.model),
                                ("Problems - LeetCode", .learned), ("Two Sum | HackerRank", .held),
                                ("Problem - 1801A - Codeforces", .model)] {
            XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Math", app: "Google Chrome", title: title, text: "", source: source).category, title.lowercased().contains("leetcode") ? "LeetCode" : "SWE", title)
        }
        XCTAssertTrue(ScreenClassificationPolicy.isCodingPractice(title: "Untitled", url: "https://leetcode.com/problems/two-sum/"))
        XCTAssertFalse(ScreenClassificationPolicy.isCodingPractice(title: "How LeetCode changed hiring - The Atlantic"))
        XCTAssertFalse(ScreenClassificationPolicy.isCodingPractice(title: "Leetcode grind plan - Google Docs"))
    }

    func testJournalAppIsJournalingWhateverTheEntrySays() {
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Math", app: "Journal", title: "All Entries",
                                                           text: "Update to math midterm", source: .model).category, "Journaling")
        XCTAssertTrue(ScreenClassificationPolicy.isJournalApp(app: "Journal", bundle: "com.apple.journal"))
        XCTAssertFalse(ScreenClassificationPolicy.isJournalApp(app: "Google Chrome", bundle: "com.google.Chrome"))
    }

    func testXHomeFeedIsLeisure() {
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Admin", app: "Google Chrome", title: "(17) Home / X", text: "").category, "Leisure")
    }

    func testNewsFeedsShoppingAndForumsAreNotReading() {
        for title in ["Breaking news — latest headlines", "Home • Threads", "Shopping cart — Amazon.com",
                      "Hacker News", "r/popular", "What's happening | Reddit", "Forum: latest topics"] {
            XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: title, text: "").category, "Leisure", title)
        }
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Bill payment", text: "").category, "Admin")
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Facebook account settings", text: "").category, "Admin")
    }

    func testOldReadingLabelsNeedFreshEvidenceWhenPageIsClearlyBrowsing() {
        for source in [ScreenClassificationPolicy.Source.learned, .held] {
            let result = ScreenClassificationPolicy.evaluate(category: "Reading", app: "Chrome", title: "Breaking news", text: "", source: source)
            XCTAssertNil(result.category)
            XCTAssertTrue(result.uncertain)
        }
        XCTAssertEqual(ScreenClassificationPolicy.evaluate(category: "SWE", app: "Chrome", title: "Forum: latest topics", text: "", source: .learned).category, "SWE")
    }

    func testCasualChatIsNotAutomaticallyReading() {
        let result = ScreenClassificationPolicy.evaluate(category: "Reading", app: "ChatGPT", title: "Dinner plans", text: "What should we eat tonight?")
        XCTAssertNil(result.category)
        XCTAssertTrue(result.uncertain)
    }
}
