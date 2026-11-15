import XCTest
@testable import FocusCore

final class AIChatsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveMessagesInTheConversationYouAreWatching() {
        let a = AIChats.WindowRead(tool: "ChatGPT", title: "ChatGPT", messages: [], at: t0)
        let b = AIChats.WindowRead(tool: "ChatGPT", title: "ChatGPT", messages: ["what is keepdim"], at: t0 + 4)
        let new = AIChats.newMessages(previous: a, current: b, seenIDs: [], seenText: [])
        XCTAssertEqual(new.map(\.text), ["what is keepdim"])
        XCTAssertFalse(new[0].backfill)
        // Renamed after the first answer: same conversation, nothing new.
        let c = AIChats.WindowRead(tool: "ChatGPT", title: "Keepdim in torch", messages: ["what is keepdim"], at: t0 + 8)
        XCTAssertTrue(AIChats.newMessages(previous: b, current: c, seenIDs: Set(new.map(\.id)), seenText: []).isEmpty)
        let d = AIChats.WindowRead(tool: "ChatGPT", title: "Keepdim in torch", messages: ["what is keepdim", "and broadcasting?"], at: t0 + 12)
        let more = AIChats.newMessages(previous: c, current: d, seenIDs: Set(new.map(\.id)), seenText: [])
        XCTAssertEqual(more.map(\.text), ["and broadcasting?"])
        XCTAssertEqual(more[0].conversation, "Keepdim in torch")
        XCTAssertFalse(more[0].backfill)
    }

    func testRepliesCountForMessagesYouSentWhileWatchingAsTheyGrow() {
        let old = AIChats.WindowRead(tool: "Claude", title: "Bayes", messages: ["explain bayes"], replies: [300], at: t0)
        let backfill = AIChats.newMessages(previous: nil, current: old, seenIDs: [], seenText: [])
        XCTAssertTrue(backfill[0].backfill)
        let a = AIChats.WindowRead(tool: "Claude", title: "Bayes", messages: ["explain bayes", "and priors?"], replies: [300, 40], at: t0 + 4)
        let new = AIChats.newMessages(previous: old, current: a, seenIDs: Set(backfill.map(\.id)), seenText: [])
        XCTAssertEqual(new.map(\.id), [AIChats.messageIDs(a)[1]])
        let live = Set(new.filter { !$0.backfill }.map(\.id))
        let first = AIChats.replyGrowth(a, live: live, counted: [:])
        XCTAssertEqual(first.map(\.words), [40])
        XCTAssertEqual(first.map(\.added), [40])
        var b = a; b.replies = [300, 250]; b.at = t0 + 8
        let more = AIChats.replyGrowth(b, live: live, counted: [first[0].id: 40])
        XCTAssertEqual(more.map(\.added), [210])
        XCTAssertTrue(AIChats.replyGrowth(b, live: live, counted: [first[0].id: 250]).isEmpty)
        var cut = b; cut.replies = [300]
        XCTAssertTrue(AIChats.replyGrowth(cut, live: live, counted: [:]).isEmpty)
    }

    func testOpeningAnOldConversationIsBackfillOnce() {
        let old = AIChats.WindowRead(tool: "ChatGPT", title: "Bayes", messages: ["explain bayes", "again please"], at: t0)
        let first = AIChats.newMessages(previous: nil, current: old, seenIDs: [], seenText: [])
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy(\.backfill))
        let seenText = Set(first.map(\.textKey))
        let reopened = AIChats.WindowRead(tool: "ChatGPT", title: "Bayes", messages: ["again please"], at: t0 + 3600)
        XCTAssertTrue(AIChats.newMessages(previous: nil, current: reopened, seenIDs: [], seenText: seenText).isEmpty)
    }

    func testAskingTheSameThingTwiceLiveCountsTwice() {
        let a = AIChats.WindowRead(tool: "Claude", title: "Q", messages: ["why"], at: t0)
        let ids = Set(AIChats.newMessages(previous: nil, current: a, seenIDs: [], seenText: []).map(\.id))
        let b = AIChats.WindowRead(tool: "Claude", title: "Q", messages: ["why", "why"], at: t0 + 5)
        let new = AIChats.newMessages(previous: a, current: b, seenIDs: ids, seenText: [])
        XCTAssertEqual(new.count, 1)
        XCTAssertFalse(new[0].backfill)
    }

    func testClaudeCodePromptsOnly() {
        func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let base: [String: Any] = ["type": "user", "timestamp": "2026-11-08T18:01:02.345Z", "cwd": "/Users/m/Code/focus",
                                   "sessionId": "s1", "uuid": "u1"]
        var p = base; p["message"] = ["role": "user", "content": "fix the switcher"]
        XCTAssertEqual(AIChats.claudeCodePrompt(line(p))?.text, "fix the switcher")
        XCTAssertEqual(AIChats.claudeCodePrompt(line(p))?.project, "focus")
        var tool = base; tool["message"] = ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]
        XCTAssertNil(AIChats.claudeCodePrompt(line(tool)))
        var meta = p; meta["isMeta"] = true
        XCTAssertNil(AIChats.claudeCodePrompt(line(meta)))
        var sys = p; sys["promptSource"] = "system"
        XCTAssertNil(AIChats.claudeCodePrompt(line(sys)))
        var tag = base; tag["message"] = ["role": "user", "content": "<command-name>/clear</command-name>"]
        XCTAssertNil(AIChats.claudeCodePrompt(line(tag)))
        var blocks = base; blocks["message"] = ["role": "user", "content": [["type": "text", "text": "look at this"], ["type": "image"]]]
        XCTAssertEqual(AIChats.claudeCodePrompt(line(blocks))?.text, "look at this")
        var summary = base; summary["isCompactSummary"] = true
        summary["message"] = ["role": "user", "content": "This session is being continued from a previous conversation that ran out of context."]
        XCTAssertNil(AIChats.claudeCodePrompt(line(summary)))
        summary["isCompactSummary"] = nil
        XCTAssertNil(AIChats.claudeCodePrompt(line(summary)))
    }

    func testCodexSkipsInjectedTurns() {
        func line(_ text: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": "2026-11-08T18:01:02Z",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        }
        XCTAssertNil(AIChats.codexPrompt(line("<environment_context>cwd</environment_context>"), cwd: nil))
        XCTAssertNil(AIChats.codexPrompt(line("Agent mail from Claude (follow these"), cwd: nil))
        XCTAssertNil(AIChats.codexPrompt(line("[46] tool exec call: text(await tools.exec_command({cmd:\"ls\"}))"), cwd: nil))
        XCTAssertNil(AIChats.codexPrompt(line("[54] assistant: The check-in tests pass."), cwd: nil))
        XCTAssertNil(AIChats.codexPrompt(line("# AGENTS.md instructions for /x"), cwd: nil))
        XCTAssertEqual(AIChats.codexPrompt(line("# Context from my IDE setup:\nfoo\n## My request for Codex:\nadd tests"), cwd: "/a/focus")?.text, "add tests")
        XCTAssertEqual(AIChats.codexPrompt(line("make the popup wider"), cwd: "/a/focus")?.project, "focus")
        XCTAssertNil(AIChats.codexPrompt(line("The following is the Codex agent history whose request action you are assessing."), cwd: nil))
        XCTAssertEqual(AIChats.codexText("# Files pasted by the user:\n## \"nb\"\n## My request for Codex\nfix the shape bug"), "fix the shape bug")
    }

    func testExportsFromBothTools() throws {
        let chatgpt: [[String: Any]] = [["title": "Bigram", "mapping": [
            "a": ["message": ["id": "m1", "author": ["role": "user"], "create_time": 1_800_000_000.5,
                              "content": ["content_type": "text", "parts": ["set up the bigram"]]]],
            "b": ["message": ["id": "m2", "author": ["role": "assistant"], "create_time": 1_800_000_001.0,
                              "content": ["content_type": "text", "parts": ["Sure"]]]],
            "c": ["message": NSNull()],
        ]]]
        let g = AIChats.exportMessages(try JSONSerialization.data(withJSONObject: chatgpt))
        XCTAssertEqual(g.map(\.text), ["set up the bigram"])
        XCTAssertEqual(g[0].tool, "ChatGPT")
        XCTAssertEqual(g[0].conversation, "Bigram")
        let claude: [[String: Any]] = [["name": "Bayes", "chat_messages": [
            ["uuid": "x", "sender": "human", "text": "explain bayes", "created_at": "2026-11-01T10:00:00.000000+00:00"],
            ["uuid": "y", "sender": "assistant", "text": "Bayes says", "created_at": "2026-11-01T10:00:05Z"],
        ]]]
        let c = AIChats.exportMessages(try JSONSerialization.data(withJSONObject: claude))
        XCTAssertEqual(c.map(\.text), ["explain bayes"])
        XCTAssertEqual(c[0].tool, "Claude")
    }

    func testDedupPrefersExactTimes() {
        let w = AIChats.Message(id: "w", at: t0, tool: "ChatGPT", conversation: nil, text: "Explain  Bayes", source: .window, backfill: true)
        let e = AIChats.Message(id: "e", at: t0 - 7200, tool: "ChatGPT", conversation: "Bayes", text: "explain bayes", source: .export)
        let other = AIChats.Message(id: "o", at: t0 + 86400 * 3, tool: "ChatGPT", conversation: nil, text: "explain bayes", source: .window)
        let d = AIChats.deduplicated([w, e, other])
        XCTAssertEqual(d.map(\.id), ["e", "o"])
    }

    func testClaudeWindowReadOfACodePromptIsTheTranscriptsMessage() {
        let typed = AIChats.Message(id: "cc", at: t0, tool: "Claude Code", conversation: "s", text: "add the insights page", source: .transcript)
        let seen = AIChats.Message(id: "w", at: t0 + 3, tool: "Claude", conversation: nil, text: "Add the  insights page", source: .window)
        let chat = AIChats.Message(id: "c", at: t0 + 60, tool: "Claude", conversation: "Papers", text: "summarize the papers", source: .window)
        let sameWordsToCodex = AIChats.Message(id: "cx", at: t0 + 90, tool: "Codex", conversation: nil, text: "add the insights page", source: .transcript)
        XCTAssertEqual(AIChats.deduplicated([typed, seen, chat, sameWordsToCodex]).map(\.id), ["cc", "c", "cx"])
    }
}
