import XCTest
@testable import FocusCore

final class CoachEpisodeTests: XCTestCase {
    private func row(_ text: String = "An article about proofs", at: Date = Date(), url: String? = nil,
                     privacy: ScreenJournal.Privacy = .notBrowser) -> ScreenJournal.Row {
        .init(at: at, end: at.addingTimeInterval(15), app:"App",bundle:"app",windowID:"1",title:"Article",
              url:url, category:"Reading",trackedCategory:"Reading",active:true,idleSeconds:0,privacy:privacy,evidenceImageID:UUID(),text:text)
    }
    private var valid: [String: Any] {
        ["topic":"Partial orders", "course":NSNull(), "activity":"reading", "concepts":["posets"],
         "summary":"A partial-order definition is visible.", "notes":["Reflexivity is listed."], "questions":[],
         "transcription":NSNull(), "diagram":false, "unreadable":false, "struggle":NSNull(), "confidence":"high"]
    }
    func testOnlyMeaningfulChangesAndLowerRateSocialFeedsQueue() {
        let at = Date(); let first = row(at: at)
        let checkpoint = CoachEpisode.Checkpoint(row: first, visualHash: 0)
        let same = row(at: at.addingTimeInterval(15))
        XCTAssertFalse(CoachEpisode.meaningful(row:same,text:same.text!,visualHash:0,previous:checkpoint,previousText:first.text))
        XCTAssertTrue(CoachEpisode.meaningful(row:same,text:same.text!,visualHash:UInt64.max,previous:checkpoint,previousText:first.text))
        let feed = row(at:at,url:"https://x.com/home",privacy:.regular)
        let next = row("new post",at:at.addingTimeInterval(30),url:"https://x.com/home",privacy:.regular)
        XCTAssertFalse(CoachEpisode.meaningful(row:next,text:next.text!,visualHash:UInt64.max,
            previous:.init(row:feed,visualHash:0),previousText:feed.text))
        XCTAssertFalse(CoachEpisode.sourceAllowed(row:row(privacy:.unknown),text:"An article about proofs"))
    }
    func testSecretsAndMismatchedEvidenceNeverFormPayloads() {
        for text in ["xai-abcdefghijklmnopqrstuv", "password = verylongpasswordvalue", "sk-ant-abcdefghijklmnopqrstuv"] {
            let source = row(text)
            XCTAssertFalse(CoachEpisode.sourceAllowed(row:source,text:text))
        }
        let source = row(url:"https://example.org/?access_token=secret")
        XCTAssertFalse(CoachEpisode.sourceAllowed(row:source,text:source.text!))
        XCTAssertFalse(CoachEpisode.sourceAllowed(row:row(),text:"different evidence"))
    }
    func testStructuredOutputAbstentionEscalatesAndInvalidClaimsAreRejected() throws {
        XCTAssertFalse(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:valid)).needsStrongPass)
        var diagram = valid; diagram["diagram"] = true
        XCTAssertTrue(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:diagram)).needsStrongPass)
        var unreadable = valid; unreadable["unreadable"] = true
        XCTAssertTrue(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:unreadable)).needsStrongPass)
        var bad = valid; bad["course"] = String(repeating:"x",count:200)
        XCTAssertThrowsError(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:bad)))
        bad = valid; bad["execute"] = "tool command"
        XCTAssertThrowsError(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:bad)))
        bad = valid; bad.removeValue(forKey:"unreadable")
        XCTAssertThrowsError(try CoachEpisode.decode(JSONSerialization.data(withJSONObject:bad)))
    }
    func testDurableQueueDoesNotRetryUnknownOrDuplicateRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let queue = try CoachEpisodeQueue(directory:directory)
        let source = row()
        try await queue.enqueue(row:source,visualHash:0)
        try await queue.enqueue(row:source,visualHash:0)
        let pending = await queue.next()
        XCTAssertEqual(pending?.id,source.id)
        try await queue.set(source.id,phase:.inFlight)
        let restarted = try CoachEpisodeQueue(directory:directory)
        let unknown = await restarted.next()
        XCTAssertNil(unknown)
        try await restarted.remove(bundle:"app")
        let cleared = await restarted.latestCheckpoint()
        XCTAssertNil(cleared)
    }
    func testDryRunPreviewIsNotConsideredSentAndDeletionRemovesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let queue = try CoachEpisodeQueue(directory:directory)
        let source = row()
        try await queue.enqueue(row:source,visualHash:0)
        try await queue.preview(source.id,payload:Data("{}".utf8))
        let pending = await queue.next()
        let preview = await queue.next(includePreviews:true)
        XCTAssertNil(pending)
        XCTAssertEqual(preview?.id,source.id)
        try await queue.remove(bundle:nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("previews/\(source.id.uuidString).json").path))
    }
}
