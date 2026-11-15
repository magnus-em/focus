import XCTest
@testable import FocusCore

final class AIUsageTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }()
    private lazy var day = cal.date(from: DateComponents(year: 2026, month: 11, day: 13))!
    private func t(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }

    private func seg(_ a: Double, _ b: Double, bundle: String, url: String? = nil) -> WindowTimeline.LabeledSegment {
        .init(segment: .init(start: t(a), end: t(b), app: bundle, bundle: bundle, url: url), category: nil, source: .none)
    }

    private func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testProvidersFromAppsSitesAndTools() {
        XCTAssertEqual(AIUsage.provider(bundle: "com.openai.codex", url: nil), .openAI)
        XCTAssertEqual(AIUsage.provider(bundle: "com.anthropic.claudefordesktop", url: nil), .anthropic)
        XCTAssertEqual(AIUsage.provider(bundle: "com.google.GeminiMacOS", url: nil), .google)
        XCTAssertEqual(AIUsage.provider(bundle: "com.google.Chrome", url: "https://claude.ai/chat/1"), .anthropic)
        XCTAssertNil(AIUsage.provider(bundle: "com.google.Chrome", url: "https://leetcode.com/problems/two-sum/"))
        XCTAssertNil(AIUsage.provider(bundle: "com.microsoft.VSCode", url: nil))
        XCTAssertEqual(AIUsage.provider(tool: "Codex"), .openAI)
        XCTAssertEqual(AIUsage.provider(tool: "Claude Code"), .anthropic)
    }

    func testClaudeCodeLines() {
        let reply = line(["type": "assistant", "timestamp": "2026-11-13T15:00:00.000Z",
                          "message": ["model": "claude-opus-5-5", "content": [["type": "thinking", "thinking": "hidden words here"],
                                                                             ["type": "text", "text": "Three words here"],
                                                                             ["type": "tool_use", "name": "Bash"]]]])
        XCTAssertEqual(AIUsage.claudeCodeWork(reply)?.words, 3)
        XCTAssertEqual(AIUsage.claudeCodeWork(reply, automated: true)?.words, 0)
        let tool = line(["type": "user", "timestamp": "2026-11-13T15:00:05.000Z",
                         "message": ["content": [["type": "tool_result", "content": "ok"]]]])
        XCTAssertEqual(AIUsage.claudeCodeWork(tool)?.words, 0)
        let prompt = line(["type": "user", "timestamp": "2026-11-13T15:01:00.000Z", "message": ["content": "do the thing"]])
        XCTAssertNil(AIUsage.claudeCodeWork(prompt))
        XCTAssertFalse(AIUsage.claudeCodeAutomatedPrompt(prompt))
        let scheduled = line(["type": "user", "promptSource": "system", "timestamp": "2026-11-13T08:30:00.000Z",
                              "message": ["content": "tune the rules"]])
        XCTAssertTrue(AIUsage.claudeCodeAutomatedPrompt(scheduled))
        let synthetic = line(["type": "assistant", "timestamp": "2026-11-13T15:00:00.000Z",
                              "message": ["model": "<synthetic>", "content": [["type": "text", "text": "No response requested."]]]])
        XCTAssertNil(AIUsage.claudeCodeWork(synthetic))
    }

    func testCodexLines() {
        let reply = line(["type": "response_item", "timestamp": "2026-11-13T15:00:00.000Z",
                          "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Here is the answer."]]]])
        XCTAssertEqual(AIUsage.codexWork(reply)?.words, 4)
        let mine = line(["type": "response_item", "timestamp": "2026-11-13T15:00:00.000Z",
                         "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]]])
        XCTAssertNil(AIUsage.codexWork(mine))
        let call = line(["type": "response_item", "timestamp": "2026-11-13T15:00:00.000Z", "payload": ["type": "custom_tool_call"]])
        XCTAssertEqual(AIUsage.codexWork(call)?.words, 0)
        XCTAssertEqual(AIUsage.codexSubagent(line(["type": "session_meta", "payload": ["source": ["subagent": ["other": "guardian"]]]])), true)
        XCTAssertEqual(AIUsage.codexSubagent(line(["type": "session_meta", "payload": ["source": "vscode"]])), false)
        XCTAssertNil(AIUsage.codexSubagent(reply))
    }

    func testMinutesMergeAcrossScans() {
        let a = AIUsage.minutes([.init(at: t(10), words: 5), .init(at: t(10).addingTimeInterval(20), words: 7)], tool: "Codex", session: "s")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].words, 12)
        let b = AIUsage.minutes([.init(at: t(10).addingTimeInterval(40), words: 3)], tool: "Codex", session: "s")
        XCTAssertEqual(AIUsage.merged(a + b).map(\.words), [15])
    }

    func testWorkTimeJoinsShortGapsAndCountsParallelSessionsOnce() {
        let s1 = (0..<10).map { AIUsage.Minute(at: t(10).addingTimeInterval(Double($0) * 120), tool: "Claude Code", session: "a", words: 0) }
        let s2 = (0..<5).map { AIUsage.Minute(at: t(10).addingTimeInterval(Double($0) * 60), tool: "Codex", session: "b", words: 10) }
        let late = AIUsage.Minute(at: t(12), tool: "Codex", session: "b", words: 0)
        let s = AIUsage.summarize(period: DateInterval(start: day, end: t(24)), segments: [], sessions: [], messages: [],
                                  minutes: s1 + s2 + [late], calendar: cal)
        XCTAssertEqual(s.workSeconds, 19 * 60 + 60, accuracy: 1)
        XCTAssertEqual(s.parallelWorkSeconds, 19 * 60 + 5 * 60 + 60, accuracy: 1)
        XCTAssertEqual(s.read, 50)
        XCTAssertEqual(s.tools.first { $0.provider == .openAI }?.read, 50)
    }

    func testTimeWordsAndCategoryShare() {
        let segments = [seg(9, 10, bundle: "com.microsoft.VSCode"), seg(10, 10.5, bundle: "com.openai.codex"),
                        seg(10.5, 11, bundle: "com.google.Chrome", url: "https://claude.ai/new"),
                        seg(11, 12, bundle: "com.google.Chrome", url: "https://leetcode.com/problems/x/"),
                        seg(12, 12.5, bundle: "com.apple.loginwindow")]
        let sessions = [Insights.Session(start: t(9), end: t(11), category: "SWE", isFocus: true),
                        Insights.Session(start: t(11), end: t(12), category: "LeetCode", isFocus: true),
                        Insights.Session(start: t(0), end: t(8), category: "Sleep", isFocus: false)]
        let messages = [AIChats.Message(id: "1", at: t(10.2), tool: "Codex", conversation: nil, text: "why does this fail", source: .transcript),
                        AIChats.Message(id: "2", at: t(10.7), tool: "Claude", conversation: nil, text: "explain", source: .window)]
        let s = AIUsage.summarize(period: DateInterval(start: day, end: t(24)), segments: segments, sessions: sessions,
                                  messages: messages, minutes: [], calendar: cal)
        XCTAssertEqual(s.aiSeconds, 3600, accuracy: 1)
        XCTAssertEqual(s.macSeconds, 3 * 3600, accuracy: 1)
        XCTAssertEqual(s.share, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(s.wrote, 5)
        XCTAssertEqual(s.messages, 2)
        XCTAssertEqual(s.categories.map(\.name), ["SWE", "LeetCode"])
        XCTAssertEqual(s.categories[0].share ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.categories[0].messages, 2)
        XCTAssertEqual(s.categories[1].share ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(s.tools.first { $0.provider == .anthropic }?.aiSeconds ?? 0, 1800, accuracy: 1)
    }
}
