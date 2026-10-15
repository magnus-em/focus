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
        /// False when xAI sent no cost and `costUSD` was priced from tokens.
        public var costIsExact: Bool
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
        let input = u["prompt_tokens"] as? Int ?? u["input_tokens"] as? Int ?? 0
        let output = u["completion_tokens"] as? Int ?? u["output_tokens"] as? Int ?? 0
        let outDetails = (u["completion_tokens_details"] ?? u["output_tokens_details"]) as? [String: Any]
        let inDetails = (u["prompt_tokens_details"] ?? u["input_tokens_details"]) as? [String: Any]
        let reasoning = outDetails?["reasoning_tokens"] as? Int ?? 0
        let image = inDetails?["image_tokens"] as? Int ?? 0
        // xAI reports exact cost in 1e-10 USD ticks (docs.x.ai cost tracking).
        let ticks = (u["cost_in_usd_ticks"] as? NSNumber).map { $0.doubleValue / 1e10 }
        let exact = ticks.map { $0.isFinite && $0 >= 0 } ?? false
        let cost = exact ? ticks! : price(model: model, input: input, output: output + reasoning)
        return Reply(json: json, usage: Usage(inputTokens: input, outputTokens: output, reasoningTokens: reasoning,
                                              imageTokens: image, costUSD: cost, costIsExact: exact),
                     model: obj["model"] as? String ?? model)
    }

    /// Base rates per million tokens (docs.x.ai, 10/15), under 200k context.
    static func price(model: String, input: Int, output: Int) -> Double {
        let (i, o) = model.hasPrefix("grok-4.3") ? (1.25, 2.5) : (2.0, 6.0)
        return (Double(input) * i + Double(output) * o) / 1_000_000
    }

    /// An upper bound for reserving budget: a UTF-8 byte per token (tokens
    /// never outnumber bytes), 2.6k tokens per screenshot (1.5–2.2k seen at
    /// 1600 px), the call's output limit, and more reasoning than the 10/15
    /// test showed (up to 12k tokens on grok-4.7 at full effort).
    public static func estimateUSD(model: String, text: String, images: Int, maxOutputTokens: Int,
                                   reasoningEffort: String? = nil) -> Double {
        let reasoning = model.hasPrefix("grok-4.3") ? 2000 : (reasoningEffort == "low" ? 6000 : 16000)
        return price(model: model, input: text.utf8.count + images * 2600 + 600, output: maxOutputTokens + reasoning)
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
/// (`Focus/coach/spend.jsonl`). Each call's estimate is written as a
/// reservation before it's sent, and the call refuses to go out if that write
/// fails, so a crash or restart mid-call can't reset the day's spend. A call
/// that fails without a reply (timeout, dropped connection, 5xx, unreadable
/// output) may still have been billed, so its estimate stays as unknown spend.
public actor CoachBudget {
    public struct Entry: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case reserved, settled, unknown }
        public var id: UUID
        public var at: Date
        public var model: String
        public var purpose: String
        public var costUSD: Double
        public var state: State
    }

    public enum Problem: Error, Equatable { case invalidAmount, ledgerUnwritable(String), ledgerUnreadable(String) }

    public let fileURL: URL
    public private(set) var dailyCapUSD: Double
    private let calendar: Calendar
    /// Latest entry per call.
    private var latest: [UUID: Entry] = [:]
    /// Set when an existing ledger couldn't be read in full; nothing is sent
    /// then, since today's spend is unknown.
    private var loadProblem: String?

    public init(fileURL: URL, dailyCapUSD: Double, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.dailyCapUSD = dailyCapUSD.isFinite && dailyCapUSD >= 0 ? dailyCapUSD : 0
        self.calendar = calendar
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            for line in try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n") {
                let e = try decoder.decode(Entry.self, from: Data(line.utf8))
                latest[e.id] = e
            }
        } catch {
            loadProblem = "\(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    public func setCap(_ usd: Double) {
        guard usd.isFinite, usd >= 0 else { return }
        dailyCapUSD = usd
    }

    /// Settled cost, plus the estimate of anything reserved or unknown
    /// (a reservation with no outcome is a call that never reported back).
    public func spent(on day: Date = Date()) -> Double {
        latest.values.filter { calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.costUSD }
    }

    public func unknownSpent(on day: Date = Date()) -> Double {
        latest.values.filter { $0.state != .settled && calendar.isDate($0.at, inSameDayAs: day) }
            .reduce(0) { $0 + $1.costUSD }
    }

    public func entries(on day: Date) -> [Entry] {
        latest.values.filter { calendar.isDate($0.at, inSameDayAs: day) }.sorted { $0.at < $1.at }
    }

    /// Runs `call` if its estimate fits under today's cap, and records what it cost.
    public func run(estimateUSD: Double, model: String, purpose: String, now: Date = Date(),
                    _ call: @Sendable () async throws -> XAIClient.Reply) async throws -> XAIClient.Reply {
        if let loadProblem { throw Problem.ledgerUnreadable(loadProblem) }
        guard estimateUSD.isFinite, estimateUSD >= 0 else { throw Problem.invalidAmount }
        let committed = spent(on: now)
        guard committed + estimateUSD <= dailyCapUSD else {
            throw XAIClient.Failure.overBudget(spent: committed, cap: dailyCapUSD)
        }
        let id = UUID()
        try write(Entry(id: id, at: now, model: model, purpose: purpose, costUSD: estimateUSD, state: .reserved))
        do {
            let reply = try await call()
            let cost = reply.usage.costUSD
            let settled = cost.isFinite && cost >= 0
            try? write(Entry(id: id, at: now, model: reply.model, purpose: purpose,
                             costUSD: settled ? cost : estimateUSD, state: settled && reply.usage.costIsExact ? .settled : .unknown))
            return reply
        } catch let XAIClient.Failure.http(status, message) where status < 500 {
            try? write(Entry(id: id, at: now, model: model, purpose: purpose, costUSD: 0, state: .settled))
            throw XAIClient.Failure.http(status, message)
        } catch {
            try? write(Entry(id: id, at: now, model: model, purpose: purpose, costUSD: estimateUSD, state: .unknown))
            throw error
        }
    }

    /// Kept in memory even when the disk write fails, so this run still counts it.
    private func write(_ e: Entry) throws {
        latest[e.id] = e
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let line = try encoder.encode(e) + Data("\n".utf8)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let h = try FileHandle(forWritingTo: fileURL)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
            try h.synchronize()
        } catch {
            throw Problem.ledgerUnwritable(error.localizedDescription)
        }
    }
}
