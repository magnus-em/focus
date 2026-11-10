import Foundation
import FocusCore

/// Writes the Insights analysis with the strongest model Focus has a key
/// for: Claude Opus (Settings → Recall key) when set, else Grok 4.7 at high
/// reasoning (Cloud AI on), from its own daily budget so it never takes the
/// screen readings' $5.
enum InsightsWriter {
    enum Failure: LocalizedError {
        case noModel
        var errorDescription: String? {
            "No model to write with: add an Anthropic key (Settings → Recall) or turn on Cloud AI with an xAI key"
        }
    }

    static let budget = CoachBudget(
        fileURL: InsightsStore.directory.appendingPathComponent("spend.jsonl"),
        dailyCapUSD: UserDefaults.standard.object(forKey: InsightsStore.budgetKey) as? Double ?? 2)

    static var available: String? {
        if RecallCoach.isConfigured { return "Claude Opus" }
        if Coach.client != nil { return "Grok 4.7" }
        return nil
    }

    static func write(facts: String, period: DateInterval) async throws -> InsightsReport.Report {
        let user = "Write this week's analysis from these facts.\n\n" + facts
        if RecallCoach.isConfigured {
            let r = try await RecallCoach.insights(system: InsightsReport.system, user: user, schema: InsightsReport.schema)
            return InsightsReport.Report(writtenAt: Date(), periodStart: period.start, periodEnd: period.end,
                                         model: RecallCoach.model, author: "Focus", costUSD: nil,
                                         content: try InsightsReport.decode(r.json))
        }
        guard let client = Coach.client else { throw Failure.noModel }
        let model = XAIClient.Model.strong
        let estimate = XAIClient.estimateUSD(model: model, text: InsightsReport.system + user, images: 0, maxOutputTokens: 8000)
        let reply = try await budget.run(estimateUSD: estimate, model: model, purpose: "insights") {
            try await client.complete(model: model, system: InsightsReport.system, text: user, schema: InsightsReport.schema,
                                      reasoningEffort: "high", maxOutputTokens: 8000, timeout: 600)
        }
        return InsightsReport.Report(writtenAt: Date(), periodStart: period.start, periodEnd: period.end,
                                     model: reply.model, author: "Focus", costUSD: reply.usage.costUSD,
                                     content: try InsightsReport.decode(reply.json))
    }
}
