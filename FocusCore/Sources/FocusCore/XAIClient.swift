import Foundation
import Security

/// xAI (Grok) chat completions with images and JSON output. Measured 10/15 on
/// real screenshots: grok-4.3 read text, LaTeX math, tables and a two-column
/// cheat sheet correctly for under a cent each; on a Hasse diagram it invented
/// edges that grok-4.7 at low reasoning effort got right.
public struct XAIClient: Sendable {
    public enum Model {
        public static let fast = "grok-4.3"
        public static let strong = "grok-4.7"
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var reasoningTokens: Int
        public var imageTokens: Int
        public var costUSD: Double
    }

    public struct Reply: Sendable {
        /// The model's JSON object, as returned.
        public var json: Data
        public var usage: Usage
        public var model: String
    }

    public enum Failure: Error, Equatable {
        case noKey
        case http(Int, String)
        case malformed
        case overBudget(spent: Double, cap: Double)
    }

    let key: String
    let session: URLSession

    public init(key: String, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    /// One call. `schema` makes the output a strict JSON schema; without it the
    /// reply is still a JSON object. Images are JPEG or PNG data.
    public func complete(model: String, system: String? = nil, text: String, images: [Data] = [],
                         schema: [String: Any]? = nil, reasoningEffort: String? = nil,
                         maxOutputTokens: Int? = nil, timeout: TimeInterval = 180) async throws -> Reply {
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(
            model: model, system: system, text: text, images: images, schema: schema,
            reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens))
        let (data, resp) = try await session.data(for: req)
        return try Self.parse(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0, model: model)
    }

    static func body(model: String, system: String?, text: String, images: [Data], schema: [String: Any]?,
                     reasoningEffort: String?, maxOutputTokens: Int?) -> [String: Any] {
        var content: [[String: Any]] = images.map { img in
            let mime = img.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            return ["type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(img.base64EncodedString())", "detail": "high"]]
        }
        content.append(["type": "text", "text": text])
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": content])
        var body: [String: Any] = ["model": model, "messages": messages]
        body["response_format"] = schema.map {
            ["type": "json_schema", "json_schema": ["name": "result", "schema": $0, "strict": true]]
        } ?? ["type": "json_object"]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        if let maxOutputTokens { body["max_completion_tokens"] = maxOutputTokens }
        return body
    }

    static func parse(_ data: Data, status: Int, model: String) throws -> Reply {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let err = obj["error"]
            let msg = (err as? [String: Any])?["message"] as? String ?? err as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(status, String(msg.prefix(500)))
        }
        guard let message = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]),
              let content = message["content"] as? String,
              let json = content.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: json)) is [String: Any] else { throw Failure.malformed }
        let u = obj["usage"] as? [String: Any] ?? [:]
        let input = u["prompt_tokens"] as? Int ?? 0
        let output = u["completion_tokens"] as? Int ?? 0
        let reasoning = (u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        let image = (u["prompt_tokens_details"] as? [String: Any])?["image_tokens"] as? Int ?? 0
        // xAI reports exact cost in 1e-10 USD ticks; price it from tokens if absent.
        let cost = (u["cost_in_usd_ticks"] as? NSNumber).map { $0.doubleValue / 1e10 }
            ?? price(model: model, input: input, output: output + reasoning)
        return Reply(json: json, usage: Usage(inputTokens: input, outputTokens: output, reasoningTokens: reasoning,
                                              imageTokens: image, costUSD: cost),
                     model: obj["model"] as? String ?? model)
    }

    /// Base rates per million tokens (docs.x.ai, 10/15), under 200k context.
    static func price(model: String, input: Int, output: Int) -> Double {
        let (i, o) = model.hasPrefix("grok-4.3") ? (1.25, 2.5) : (2.0, 6.0)
        return (Double(input) * i + Double(output) * o) / 1_000_000
    }

    /// A deliberately high guess for reserving budget: ~2.2k tokens per
    /// 1600 px screenshot, 4 characters per token, and the reasoning seen in
    /// the 10/15 test (up to 12k tokens on grok-4.7 at full effort).
    public static func estimateUSD(model: String, textCharacters: Int, images: Int, outputTokens: Int = 1500,
                                   reasoningEffort: String? = nil) -> Double {
        let reasoning = model.hasPrefix("grok-4.3") ? 1000 : (reasoningEffort == "low" ? 3500 : 12000)
        return price(model: model, input: textCharacters / 4 + images * 2200 + 400, output: outputTokens + reasoning)
    }
}

/// The key the user gave for Focus, in the login Keychain.
public enum XAIKey {
    public static let service = "com.magnus.focus.xai"

    public static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}

/// A daily dollar cap across every cloud call, with a ledger on disk
/// (`Focus/coach/spend.jsonl`). A call reserves its estimate first, so
/// concurrent calls can't jointly overshoot; a call that fails without a
/// reply (timeout, dropped connection) may still have been billed, so its
/// estimate is recorded as unknown spend rather than dropped.
public actor CoachBudget {
    public struct Entry: Codable, Equatable, Sendable {
        public var at: Date
        public var model: String
        public var purpose: String
        public var costUSD: Double
        /// True when the call's outcome is unknown and `costUSD` is its estimate.
        public var unknown: Bool
    }

    public let fileURL: URL
    public var dailyCapUSD: Double
    private let calendar: Calendar
    private var entries: [Entry]
    private var reserved: [UUID: Double] = [:]

    public init(fileURL: URL, dailyCapUSD: Double, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.dailyCapUSD = dailyCapUSD
        self.calendar = calendar
        let lines = (try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n") ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = lines.compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    public func setCap(_ usd: Double) { dailyCapUSD = usd }

    public func spent(on day: Date = Date()) -> Double {
        entries.filter { calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.costUSD }
    }

    public func unknownSpent(on day: Date = Date()) -> Double {
        entries.filter { $0.unknown && calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.costUSD }
    }

    public func entries(on day: Date) -> [Entry] { entries.filter { calendar.isDate($0.at, inSameDayAs: day) } }

    /// Runs `call` if its estimate fits under today's cap, and records what it cost.
    public func run(estimateUSD: Double, model: String, purpose: String, now: Date = Date(),
                    _ call: @Sendable () async throws -> XAIClient.Reply) async throws -> XAIClient.Reply {
        let committed = spent(on: now) + reserved.values.reduce(0, +)
        guard committed + estimateUSD <= dailyCapUSD else {
            throw XAIClient.Failure.overBudget(spent: committed, cap: dailyCapUSD)
        }
        let id = UUID()
        reserved[id] = estimateUSD
        defer { reserved[id] = nil }
        do {
            let reply = try await call()
            record(Entry(at: now, model: reply.model, purpose: purpose, costUSD: reply.usage.costUSD, unknown: false))
            return reply
        } catch let f as XAIClient.Failure {
            if case .malformed = f {
                record(Entry(at: now, model: model, purpose: purpose, costUSD: estimateUSD, unknown: true))
            }
            throw f
        } catch {
            record(Entry(at: now, model: model, purpose: purpose, costUSD: estimateUSD, unknown: true))
            throw error
        }
    }

    private func record(_ e: Entry) {
        entries.append(e)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let line = try? encoder.encode(e) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(line + Data("\n".utf8))
            try? h.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: fileURL)
        }
    }
}
