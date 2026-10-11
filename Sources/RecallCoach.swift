import Foundation
import Security
import FocusCore

/// Claude as a retrieval coach: reads post-session recall, drafts review
/// cards, grades answers against the reference, and gives graded hints.
/// Optional — everything in Recall works without a key.
enum RecallCoach {
    struct NoteReview {
        let feedback: String
        let cards: [RecallCardDraft]
    }

    struct Grade {
        let score: RecallGrade
        let feedback: String
    }

    enum CoachError: LocalizedError {
        case noKey, http(Int, String), refused, malformed

        var errorDescription: String? {
            switch self {
            case .noKey: return "Add a Claude API key in Settings → Recall."
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .refused: return "Claude declined this request."
            case .malformed: return "Couldn't read Claude's reply."
            }
        }
    }

    static let model = "claude-opus-5-5"

    // MARK: - Key

    private static let keychainService = "com.magnus.focus.anthropic"

    static var apiKey: String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    static var isConfigured: Bool { apiKey != nil }

    static func setAPIKey(_ key: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Calls

    private static let coachSystem = """
    You are a learning coach inside a focus-timer app used by a Yale CS student preparing for quant and \
    software-engineering interviews. The student practices retrieval: they write what they remember \
    without notes, then check it. Your job is to make that checking accurate and useful.

    Principles:
    - Judge content, not wording. Accept answers that are semantically equivalent to the reference.
    - Be specific about errors: name the exact claim that is wrong and state the correct version.
    - Distinguish forgetting a name or detail from not understanding the mechanism; say which it is.
    - Be brief and direct. No praise padding, no restating the whole answer, no motivational language.
    - If you are not confident something is correct, say so rather than inventing certainty.
    - Never make medical or neurological claims.
    """

    /// Feedback on a post-session free recall plus up to two cards for later retrieval.
    static func reviewNote(_ text: String, course: String, minutes: Double) async throws -> NoteReview {
        let user = """
        The student just finished a \(Int(minutes))-minute \(course.isEmpty ? "study" : course) session and, \
        without notes, wrote the most important thing they learned:

        <recall>
        \(text)
        </recall>

        1. feedback: 2–4 sentences. What they reconstructed correctly, any factual errors or misconceptions \
        (quote the claim and correct it), and the most important missing piece if one is obvious. If the note \
        is too vague to check (e.g. "did homework"), say what a more useful recall would include.
        2. cards: 0–2 retrieval prompts for the most important ideas in the note — only ideas worth \
        remembering in a month. Prefer prompts that require explaining, deriving, reconstructing an algorithm, \
        comparing, or applying, over definitions. The prompt must not contain or give away the answer \
        (don't name the concept if naming it is the answer). The answer is a concise, correct reference \
        (1–6 sentences, or short code/math), correcting any errors in the student's note. Return no cards \
        if there is nothing concrete enough.
        """
        let json = try await call(user: user, schema: cardsSchema(withFeedback: true))
        return NoteReview(feedback: json["feedback"] as? String ?? "", cards: parseCards(json))
    }

    /// Cards drafted from pasted material (lecture notes, a textbook section…).
    static func draftCards(from material: String, course: String, max: Int) async throws -> [RecallCardDraft] {
        let user = """
        Draft up to \(max) retrieval-practice cards for a \(course.isEmpty ? "CS/quant" : course) student \
        from this material. Pick the ideas most worth remembering in a month, not every fact.

        <material>
        \(material)
        </material>

        Prefer prompts that require explaining, deriving, reconstructing an algorithm, comparing, or applying, \
        over definitions. A prompt must not contain or give away its answer. Each answer is a concise, correct \
        reference (1–6 sentences, or short code/math). Base answers on the material; where the material is \
        wrong or incomplete, use the correct version.
        """
        let json = try await call(user: user, schema: cardsSchema(withFeedback: false))
        return parseCards(json)
    }

    /// Suggested grade + what was missing or wrong.
    static func grade(prompt: String, reference: String, response: String) async throws -> Grade {
        let user = """
        Grade this retrieval attempt. The student answered from memory before seeing the reference.

        <prompt>\(prompt)</prompt>
        <reference>\(reference)</reference>
        <student_answer>\(response)</student_answer>

        score: 0 = could not produce the key idea (or wrong), 1 = partially right with real gaps or errors, \
        2 = correct on the essentials, 3 = correct, complete and clearly explained.
        feedback: 1–3 sentences on exactly what was missing or wrong, and whether it looks like a forgotten \
        name/detail or a gap in understanding. If the answer is fully correct, say so in a few words. If the \
        reference itself looks wrong, say that.
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "score": ["type": "integer", "enum": [0, 1, 2, 3]],
                "feedback": ["type": "string"],
            ],
            "required": ["score", "feedback"],
            "additionalProperties": false,
        ]
        let json = try await call(user: user, schema: schema)
        guard let s = json["score"] as? Int, let g = RecallGrade(rawValue: s) else { throw CoachError.malformed }
        return Grade(score: g, feedback: json["feedback"] as? String ?? "")
    }

    /// A hint one step stronger than the ones already given, never the answer itself.
    static func hint(prompt: String, reference: String, previous: [String], partial: String) async throws -> String {
        let prior = previous.isEmpty ? "none" : previous.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let user = """
        The student is stuck retrieving an answer from memory. Give hint #\(previous.count + 1): one sentence, \
        a little stronger than the previous hints, that cues the memory without stating the answer. \
        Early hints point at the context or first step; later ones may name a key ingredient.

        <prompt>\(prompt)</prompt>
        <reference>\(reference)</reference>
        <previous_hints>\(prior)</previous_hints>
        <what_they_have_so_far>\(partial.isEmpty ? "nothing yet" : partial)</what_they_have_so_far>
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["hint": ["type": "string"]],
            "required": ["hint"],
            "additionalProperties": false,
        ]
        let json = try await call(user: user, schema: schema)
        guard let h = json["hint"] as? String else { throw CoachError.malformed }
        return h
    }

    // MARK: - Plumbing

    private static func cardsSchema(withFeedback: Bool) -> [String: Any] {
        let card: [String: Any] = [
            "type": "object",
            "properties": [
                "prompt": ["type": "string"],
                "answer": ["type": "string"],
                "kind": ["type": "string", "enum": KnowledgeKind.allCases.map(\.rawValue)],
                "topic": ["type": "string"],
            ],
            "required": ["prompt", "answer", "kind", "topic"],
            "additionalProperties": false,
        ]
        var props: [String: Any] = ["cards": ["type": "array", "items": card]]
        var required = ["cards"]
        if withFeedback {
            props["feedback"] = ["type": "string"]
            required.insert("feedback", at: 0)
        }
        return ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    private static func parseCards(_ json: [String: Any]) -> [RecallCardDraft] {
        (json["cards"] as? [[String: Any]] ?? []).compactMap { c in
            guard let p = c["prompt"] as? String, let a = c["answer"] as? String else { return nil }
            return RecallCardDraft(prompt: p, answer: a,
                                   kind: KnowledgeKind(rawValue: c["kind"] as? String ?? "") ?? .concept,
                                   topic: c["topic"] as? String ?? "")
        }
    }

    private static func call(user: String, schema: [String: Any]) async throws -> [String: Any] {
        guard let key = apiKey else { throw CoachError.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "system": coachSystem,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw CoachError.http(status, msg)
        }
        if obj["stop_reason"] as? String == "refusal" { throw CoachError.refused }
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let d = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw CoachError.malformed }
        return json
    }
}
