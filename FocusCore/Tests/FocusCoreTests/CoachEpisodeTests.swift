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
         "summary":"A partial-order definition is visible.", "notes":["Reflexivity is listed."], "askedByUser":[], "onScreenPrompts":[],
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

    private func chatRow(bundle: String = "com.openai.codex", app: String = "ChatGPT", title: String = "Explain Two Problems",
                         category: String = "Math") -> ScreenJournal.Row {
        .init(at: Date(timeIntervalSince1970: 1_792_080_000), end: Date(timeIntervalSince1970: 1_792_080_015), app: app,
              bundle: bundle, windowID: "1", title: title, url: nil, category: category, trackedCategory: "Math", active: true,
              idleSeconds: 0, privacy: .notBrowser, evidenceImageID: UUID(), text: "x")
    }

    /// An episode-1 line as the worker wrote it on 10/15: one mixed `questions` list.
    private func legacyLine(_ row: ScreenJournal.Row, activity: String, questions: [String]) throws -> Data {
        let u = CoachEpisode.Understanding(topic: "Graph isomorphism", course: nil, activity: activity, concepts: [],
                                           summary: "s", notes: [], askedByUser: [], onScreenPrompts: [], transcription: nil,
                                           diagram: false, unreadable: false, struggle: nil, confidence: .high)
        let record = CoachEpisode.Record(source: row, understanding: u, model: "grok-4.3", usage: [], needsReview: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        var understanding = try XCTUnwrap(json["understanding"] as? [String: Any])
        understanding.removeValue(forKey: "askedByUser"); understanding.removeValue(forKey: "onScreenPrompts")
        understanding["questions"] = questions
        json["understanding"] = understanding; json["promptVersion"] = "episode-1"; json["schema"] = 1
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testNewRepliesSeparateTheUsersQuestionsFromOnScreenPrompts() throws {
        var reply = valid
        reply["askedByUser"] = ["Okay, and then what's Pascal's triangle identity?"]
        reply["onScreenPrompts"] = ["17(a): Write the adjacency matrix of G"]
        let u = try CoachEpisode.decode(JSONSerialization.data(withJSONObject: reply))
        XCTAssertEqual(u.askedByUser, ["Okay, and then what's Pascal's triangle identity?"])
        XCTAssertEqual(u.onScreenPrompts, ["17(a): Write the adjacency matrix of G"])
        var old = valid
        old.removeValue(forKey: "askedByUser"); old.removeValue(forKey: "onScreenPrompts"); old["questions"] = []
        XCTAssertThrowsError(try CoachEpisode.decode(JSONSerialization.data(withJSONObject: old)))
        let properties = try XCTUnwrap(CoachEpisode.schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["askedByUser"]); XCTAssertNotNil(properties["onScreenPrompts"]); XCTAssertNil(properties["questions"])
        let record = CoachEpisode.Record(source: chatRow(), understanding: u, model: "grok-4.3", usage: [], needsReview: false)
        XCTAssertEqual(record.promptVersion, "episode-2")
        XCTAssertEqual(record.schema, 2)
    }

    func testEpisodeOneRowsStillReadWithTheirQuestionsSorted() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let chat = try decoder.decode(CoachEpisode.Record.self, from: legacyLine(chatRow(), activity: "asking-ai", questions: [
            "16(d): Show graph isomorphism is an equivalence relation", "17: Label the graph first", "What is the identity map?",
            "Okay, and then what's Pascal's triangle identity?", "Write the adjacency matrix of G",
            "How many possible rearrangements of 8 students?", "When to apply inclusion-exclusion?",
            "give me the tips for what I need to know",
        ]))
        XCTAssertEqual(chat.promptVersion, "episode-1")
        XCTAssertEqual(chat.understanding.askedByUser, ["What is the identity map?", "Okay, and then what's Pascal's triangle identity?",
                                                        "When to apply inclusion-exclusion?",
                                                        "give me the tips for what I need to know"])
        XCTAssertEqual(chat.understanding.onScreenPrompts, ["16(d): Show graph isomorphism is an equivalence relation",
                                                            "17: Label the graph first", "Write the adjacency matrix of G",
                                                            "How many possible rearrangements of 8 students?"])
        let sheet = try decoder.decode(CoachEpisode.Record.self, from: legacyLine(
            chatRow(bundle: "com.apple.Preview", app: "Preview", title: "midterm1_review.pdf"), activity: "reading",
            questions: ["How many rearrangements have no student in their usual seat?", "Why is the inverse an isomorphism?"]))
        XCTAssertEqual(sheet.understanding.askedByUser, [])
        XCTAssertEqual(sheet.understanding.onScreenPrompts.count, 2)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let again = try encoder.encode(chat)
        XCTAssertFalse(String(decoding: again, as: UTF8.self).contains("\"questions\""))
        XCTAssertEqual(try decoder.decode(CoachEpisode.Record.self, from: again).understanding, chat.understanding)
    }

    func testNonStudyRowsKeepBothQuestionListsButNoCourse() {
        let u = CoachEpisode.Understanding(topic: "Review agent work", course: "CPSC 323", activity: "solving", concepts: ["x"],
                                           summary: "s", notes: [], askedByUser: ["Which direction?"], onScreenPrompts: ["p"],
                                           transcription: nil, diagram: false, unreadable: false, struggle: nil, confidence: .high)
        let admin = CoachEpisode.enforceDepth(u, row: chatRow(bundle: "com.anthropic.claudefordesktop", app: "Claude", category: "Admin"))
        XCTAssertNil(admin.course)
        XCTAssertEqual(admin.activity, "admin")
        XCTAssertEqual(admin.concepts, [])
        XCTAssertEqual(admin.askedByUser, ["Which direction?"])
        XCTAssertEqual(admin.onScreenPrompts, ["p"])
    }
}
