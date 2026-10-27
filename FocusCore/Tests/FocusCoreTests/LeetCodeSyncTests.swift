import XCTest
@testable import FocusCore

final class LeetCodeSyncTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testDecodesPublicProfile() throws {
        let json = """
        {"data":{"matchedUser":{"username":"8bCgAq0gGX","submitStatsGlobal":{"acSubmissionNum":[
          {"difficulty":"All","count":30},{"difficulty":"Easy","count":18},{"difficulty":"Medium","count":10},{"difficulty":"Hard","count":2}]}},
          "recentAcSubmissionList":[{"title":"Two Sum","titleSlug":"two-sum","timestamp":"1789499543"}]}}
        """
        let p = try LeetCodeSync.decode(Data(json.utf8))
        XCTAssertEqual(p.solved, 30)
        XCTAssertEqual(p.hard, 2)
        XCTAssertEqual(p.accepted, [.init(slug: "two-sum", title: "Two Sum", date: Date(timeIntervalSince1970: 1789499543))])
    }

    func testUnknownUserAndGarbage() {
        XCTAssertThrowsError(try LeetCodeSync.decode(Data(#"{"data":{"matchedUser":null,"recentAcSubmissionList":null}}"#.utf8))) {
            XCTAssertEqual($0 as? LeetCodeSync.SyncError, .noSuchUser)
        }
        XCTAssertThrowsError(try LeetCodeSync.decode(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? LeetCodeSync.SyncError, .unreadable)
        }
    }

    func testOneEntryPerProblemDaySkippingLogged() {
        let accepted: [LeetCodeSync.Accepted] = [
            .init(slug: "two-sum", title: "Two Sum", date: at(15, 12)),
            .init(slug: "two-sum", title: "Two Sum", date: at(15, 9)),
            .init(slug: "two-sum", title: "Two Sum", date: at(17, 12)),
            .init(slug: "set-mismatch", title: "Set Mismatch", date: at(23, 18)),
        ]
        let logged = [LeetCodeSync.Logged(id: UUID(), slug: "set-mismatch", date: at(23, 10), fromLeetCode: true)]
        let plan = LeetCodeSync.plan(accepted: accepted, logged: logged, now: at(26, 12), calendar: cal)
        XCTAssertEqual(plan, [.add(accepted[1]), .add(accepted[2])])
    }

    func testRecentAcceptsWaitForTheCard() {
        let a = LeetCodeSync.Accepted(slug: "two-sum", title: "Two Sum", date: at(26, 11, 30))
        XCTAssertEqual(LeetCodeSync.plan(accepted: [a], logged: [], now: at(26, 12), calendar: cal), [])
        XCTAssertEqual(LeetCodeSync.plan(accepted: [a], logged: [], now: at(26, 12, 31), calendar: cal), [.add(a)])
    }

    func testRepairsTheOneTypedEntryThatDay() {
        let typed = UUID()
        let a = LeetCodeSync.Accepted(slug: "course-schedule", title: "Course Schedule", date: at(27, 19))
        let logged = [LeetCodeSync.Logged(id: typed, slug: nil, date: at(27, 19, 38), fromLeetCode: true)]
        XCTAssertEqual(LeetCodeSync.plan(accepted: [a], logged: logged, now: at(28, 9), calendar: cal), [.repair(id: typed, a)])

        let b = LeetCodeSync.Accepted(slug: "two-sum", title: "Two Sum", date: at(27, 10))
        XCTAssertEqual(LeetCodeSync.plan(accepted: [a, b], logged: logged, now: at(28, 9), calendar: cal), [.add(b), .add(a)])
        let notLeetCode = [LeetCodeSync.Logged(id: typed, slug: nil, date: at(27, 19), fromLeetCode: false)]
        XCTAssertEqual(LeetCodeSync.plan(accepted: [a], logged: notLeetCode, now: at(28, 9), calendar: cal), [.add(a)])
    }

    func testDecodesExtensionHistory() throws {
        let json = """
        {"signedIn":true,"username":"8bCgAq0gGX","complete":true,
         "solved":[{"slug":"add-binary","title":"Add Binary"},{"slug":"two-sum","title":"Two Sum"},{"slug":"lru-cache","title":"LRU Cache"}],
         "accepted":[{"slug":"","title":"Add Binary","timestamp":1789000000},{"slug":"two-sum","title":"Two Sum","timestamp":1789499543},
                     {"slug":"","title":"Deleted Problem","timestamp":1789000000},{"slug":"two-sum","title":"Two Sum","timestamp":0}]}
        """
        let h = try LeetCodeSync.decodeHistory(Data(json.utf8))
        XCTAssertTrue(h.signedIn && h.complete)
        XCTAssertEqual(h.accepted.map(\.slug), ["add-binary", "two-sum"])
        XCTAssertEqual(h.undated, ["lru-cache"])
    }

    func testSignedOutHistory() throws {
        let h = try LeetCodeSync.decodeHistory(Data(#"{"signedIn":false}"#.utf8))
        XCTAssertFalse(h.signedIn)
        XCTAssertTrue(h.accepted.isEmpty)
    }
}
