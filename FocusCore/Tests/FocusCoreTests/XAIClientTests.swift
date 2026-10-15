import XCTest
@testable import FocusCore

final class XAIClientTests: XCTestCase {
    func testBodyCarriesImagesSchemaAndEffort() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 1])
        let body = XAIClient.body(model: "grok-4.7", system: "sys", text: "what is this", images: [png, jpeg],
                                  schema: ["type": "object"], reasoningEffort: "low", maxOutputTokens: 900)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 3)
        let urls = content.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        XCTAssertTrue(urls[0].hasPrefix("data:image/png;base64,"))
        XCTAssertTrue(urls[1].hasPrefix("data:image/jpeg;base64,"))
        XCTAssertEqual(content.last?["text"] as? String, "what is this")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 900)
    }

    func testParseReadsExactCostTicks() throws {
        let raw = """
        {"model":"grok-4.3","choices":[{"message":{"content":"{\\"primes\\":[2,3]}"}}],
         "usage":{"prompt_tokens":2505,"completion_tokens":273,"prompt_tokens_details":{"image_tokens":2102},
                  "completion_tokens_details":{"reasoning_tokens":566},"cost_in_usd_ticks":50943500}}
        """
        let reply = try XAIClient.parse(Data(raw.utf8), status: 200, model: "grok-4.3")
        XCTAssertEqual(reply.usage.costUSD, 0.00509435, accuracy: 1e-9)
        XCTAssertEqual(reply.usage.imageTokens, 2102)
        XCTAssertEqual(reply.usage.reasoningTokens, 566)
        XCTAssertTrue(reply.usage.costIsExact)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.json) as? [String: Any])
        XCTAssertEqual(json["primes"] as? [Int], [2, 3])
    }

    func testParseErrors() {
        XCTAssertThrowsError(try XAIClient.parse(Data(#"{"error":"bad key"}"#.utf8), status: 401, model: "grok-4.3")) {
            XCTAssertEqual($0 as? XAIClient.Failure, .http(401, "bad key"))
        }
        let notJSON = #"{"choices":[{"message":{"content":"sure! here you go"}}]}"#
        XCTAssertThrowsError(try XAIClient.parse(Data(notJSON.utf8), status: 200, model: "grok-4.3")) {
            XCTAssertEqual($0 as? XAIClient.Failure, .malformed)
        }
    }

    func testParseOtherUsageNamesAndMissingCost() throws {
        let raw = #"{"choices":[{"message":{"content":"{}"}}],"usage":{"input_tokens":1000000,"output_tokens":0}}"#
        let reply = try XAIClient.parse(Data(raw.utf8), status: 200, model: "grok-4.3")
        XCTAssertEqual(reply.usage.inputTokens, 1_000_000)
        XCTAssertFalse(reply.usage.costIsExact)
        XCTAssertEqual(reply.usage.costUSD, 1.25, accuracy: 1e-9)
    }

    func testEstimateIsAnUpperBound() {
        let e = XAIClient.estimateUSD(model: "grok-4.3", text: String(repeating: "∑", count: 1000), images: 1, maxOutputTokens: 1000)
        // 3000 UTF-8 bytes + 2600 + 600 in, 1000 + 2000 out.
        XCTAssertEqual(e, (6200 * 1.25 + 3000 * 2.5) / 1_000_000, accuracy: 1e-12)
    }

    private func reply(_ cost: Double) -> XAIClient.Reply {
        XAIClient.Reply(json: Data("{}".utf8),
                        usage: .init(inputTokens: 0, outputTokens: 0, reasoningTokens: 0, imageTokens: 0, costUSD: cost, costIsExact: true),
                        model: "grok-4.3")
    }

    func testBudgetCapsDayAndRecordsUnknownSpend() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let budget = CoachBudget(fileURL: url, dailyCapUSD: 0.10)
        let now = Date()
        _ = try await budget.run(estimateUSD: 0.03, model: "grok-4.3", purpose: "test", now: now) { self.reply(0.06) }
        do {
            _ = try await budget.run(estimateUSD: 0.05, model: "grok-4.3", purpose: "test", now: now) { self.reply(0.01) }
            XCTFail("over the cap")
        } catch let f as XAIClient.Failure {
            XCTAssertEqual(f, .overBudget(spent: 0.06, cap: 0.10))
        }
        do {
            _ = try await budget.run(estimateUSD: 0.01, model: "grok-4.3", purpose: "test", now: now) {
                throw URLError(.timedOut)
            }
        } catch {}
        do {
            _ = try await budget.run(estimateUSD: 0.01, model: "grok-4.3", purpose: "test", now: now) {
                throw XAIClient.Failure.http(502, "bad gateway")
            }
        } catch {}
        do {
            _ = try await budget.run(estimateUSD: 0.01, model: "grok-4.3", purpose: "test", now: now) {
                throw XAIClient.Failure.http(429, "slow down")
            }
        } catch {}
        let spent = await budget.spent(on: now)
        let unknown = await budget.unknownSpent(on: now)
        XCTAssertEqual(spent, 0.08, accuracy: 1e-9)
        XCTAssertEqual(unknown, 0.02, accuracy: 1e-9)
        let reloaded = CoachBudget(fileURL: url, dailyCapUSD: 0.10)
        let reloadedSpent = await reloaded.spent(on: now)
        XCTAssertEqual(reloadedSpent, 0.08, accuracy: 1e-9)
        let tomorrow = await reloaded.spent(on: now.addingTimeInterval(86400 * 2))
        XCTAssertEqual(tomorrow, 0)
    }

    func testReservationSurvivesACrashMidCall() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let budget = CoachBudget(fileURL: url, dailyCapUSD: 1)
        let now = Date()
        let started = expectation(description: "call started")
        let task = Task {
            try await budget.run(estimateUSD: 0.4, model: "grok-4.7", purpose: "test", now: now) {
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return self.reply(0.01)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let afterRestart = CoachBudget(fileURL: url, dailyCapUSD: 1)
        let inFlight = await afterRestart.spent(on: now)
        XCTAssertEqual(inFlight, 0.4, accuracy: 1e-9)
        task.cancel()
    }

    func testRefusesWhenTheLedgerCantBeWritten() async {
        let budget = CoachBudget(fileURL: URL(fileURLWithPath: "/dev/null/spend.jsonl"), dailyCapUSD: 1)
        do {
            _ = try await budget.run(estimateUSD: 0.01, model: "grok-4.3", purpose: "test") { self.reply(0.01) }
            XCTFail("sent without a reservation on disk")
        } catch let p as CoachBudget.Problem {
            if case .ledgerUnwritable = p {} else { XCTFail("\(p)") }
        } catch { XCTFail("\(error)") }
        do {
            _ = try await budget.run(estimateUSD: .nan, model: "grok-4.3", purpose: "test") { self.reply(0.01) }
            XCTFail("NaN estimate accepted")
        } catch {}
    }
}
