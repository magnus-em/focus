import Foundation

public enum ScreenClassificationPolicy {
    public enum Source: Sendable {
        case model, learned, held
    }

    public struct Decision: Equatable, Sendable {
        public var category: String?
        public var reason: String
        public var uncertain: Bool
    }

    public static func evaluate(category: String?, app: String, title: String, text: String,
                                source: Source = .model) -> Decision {
        if isEmptyAssistantScreen(app: app, title: title, text: text) {
            return Decision(category: nil, reason: "A new or empty chat does not show the task", uncertain: true)
        }
        if isFocusProjectWork(title: title, text: text) {
            return Decision(category: "Admin", reason: "Your rule: work on the Focus project is Admin", uncertain: false)
        }
        if source == .model {
            if category == "Math", showsMaterialCuriosity(title: title, text: text) {
                return Decision(category: "Reading", reason: "Exploring sauna materials, without mathematics or coursework", uncertain: false)
            }
        }
        guard let category else {
            return Decision(category: nil, reason: "Not enough evidence to identify the task", uncertain: true)
        }
        guard category == "AI" else {
            return Decision(category: category, reason: "", uncertain: false)
        }
        guard supportsMLStudy(title: title, text: text) else {
            let prefix = source == .learned ? "Earlier AI label needs fresh evidence. " : ""
            return Decision(category: nil,
                            reason: prefix + "AI means studying or researching ML/deep learning; an assistant or model integration alone is not evidence",
                            uncertain: true)
        }
        return Decision(category: category, reason: "Visible ML/deep-learning study or research material", uncertain: false)
    }

    private static func isEmptyAssistantScreen(app: String, title: String, text: String) -> Bool {
        let app = normalized(app)
        let title = normalized(title).components(separatedBy: " (").first ?? ""
        let assistant = ["chatgpt", "claude", "codex"].contains { app.contains($0) }
        let generic = ["", app, "chatgpt", "claude", "codex", "new chat", "new conversation", "untitled", "chat"].contains(title)
        guard assistant && generic else { return false }
        var content = normalized(String(text.prefix(2400)))
        let boilerplate = ["what should we work on", "how can i help you", "how can i help", "ask anything",
                           "type a message", "send a message", "new chat", "start a new conversation", "new conversation", "start a conversation",
                           "search chats", "temporary chat", "chatgpt", "claude", "codex"]
        for phrase in boilerplate { content = content.replacingOccurrences(of: phrase, with: " ") }
        let words = content.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.isEmpty || words.allSatisfy { ["chat", "work", "search", "tools", "message", "send", "today", "hello", "hi"].contains($0) }
    }

    public static func isFocusProjectWork(title: String, text: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        let body = normalized(String(text.prefix(2400)))
        let markers = ["focus app", "focus project", "focuscore", "screenwatcher.swift", "dashboardview.swift", "code/focus"]
        if title == "focus" || markers.contains(where: { title.contains($0) }) { return true }
        let project = markers.contains {
            title.contains($0) || body.contains($0)
        }
        guard project else { return false }
        let development = ["improve", "build", "implement", "redesign", "refactor", "debug", "develop", "review the codebase",
                           "install", "settings", "configure", "roadmap", "category", "work on", "working on"]
        return development.contains { body.contains($0) || title.contains($0) }
    }

    private static func showsMaterialCuriosity(title: String, text: String) -> Bool {
        let content = normalized(String(title.prefix(240)) + "\n" + String(text.prefix(2400)))
        guard content.contains("sauna"), ["wool", "insulation", "hat", "material"].contains(where: { content.contains($0) }) else { return false }
        guard !["math", "equation", "proof", "calculus", "derive", "assignment", "homework", "course", "lecture"].contains(where: { containsWordBeginning($0, in: content) }) else { return false }
        return ["what", "why", "explain", "curious"].contains { containsWordBeginning($0, in: content) }
    }

    public static func supportsMLStudy(title: String, text: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        let body = normalized(String(text.prefix(2400)))
        let domains = ["machine learning", "deep learning", "neural network", "backpropagation",
                       "gradient descent", "self attention", "self-attention", "transformer architecture",
                       "convolutional network", "reinforcement learning", "loss function", "language model training",
                       "diffusion model", "variational autoencoder", "generative adversarial network",
                       "support vector machine", "random forest", "supervised learning", "unsupervised learning",
                       "attention mechanism", "large language model", "representation learning", "contrastive learning",
                       "recurrent neural network", "policy gradient", "q-learning", "stochastic gradient"]
        let study = ["learn", "study", "research", "paper", "lecture", "tutorial", "derive", "derivation",
                     "explain", "understand", "notes", "course", "experiment", "implement", "train", "introduction"]
        let meta = ["focus app", "focuscore", "screen tracking", "screen watcher", "screenwatcher",
                    "activity tracking", "activity classifier", "classification policy", "dashboard",
                    "ai category", "ai means", "category means"]
        let titleHasDomain = domains.contains { title.contains($0) }
        let titleIsMeta = meta.contains { title.contains($0) }
        let subjectQuestion = ["what is ", "how does ", "how do ", "why "].contains { title.hasPrefix($0) }
        if titleHasDomain && !titleIsMeta && (domains.contains(title) || subjectQuestion || study.contains(where: { containsWordBeginning($0, in: title) })) {
            return true
        }
        if title == "attention is all you need" || title.hasPrefix("attention is all you need (") {
            return true
        }
        // A tracker discussing its model is evidence about building the tracker,
        // even when the discussion quotes the definition of the AI category.
        guard !meta.contains(where: { title.contains($0) || body.contains($0) }) else { return false }
        let hits = domains.filter { body.contains($0) }.count
        return hits >= 2 && study.contains { containsWordBeginning($0, in: body) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func containsWordBeginning(_ prefix: String, in value: String) -> Bool {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted).contains { $0.hasPrefix(prefix) }
    }
}

public struct LocalTaskContext: Sendable {
    private struct Observation: Codable, Sendable {
        var at: Date
        var app: String
        var title: String
        var category: String?
        var summary: String
        var excerpt: String
        var confirmed: Bool
        var uncertain: Bool
    }

    private var observations: [Observation] = []
    public let maximumAge: TimeInterval
    public let maximumObservations: Int

    public init(maximumAge: TimeInterval = 20 * 60, maximumObservations: Int = 8) {
        self.maximumAge = max(0, min(maximumAge, 60 * 60))
        self.maximumObservations = max(1, min(maximumObservations, 12))
    }

    public mutating func record(app: String, title: String, category: String?, summary: String, text: String,
                                confirmed: Bool = false, uncertain: Bool = false, at: Date = Date()) {
        observations.removeAll { at.timeIntervalSince($0.at) > maximumAge || $0.at > at }
        let observation = Observation(at: at, app: String(app.prefix(80)), title: String(title.prefix(160)),
                                      category: category.map { String($0.prefix(40)) }, summary: String(summary.prefix(160)),
                                      excerpt: String(text.prefix(240)), confirmed: confirmed, uncertain: uncertain)
        observations.removeAll { $0.app == observation.app && $0.title == observation.title }
        observations.append(observation)
        observations = Array(observations.suffix(maximumObservations))
    }

    public mutating func clear() { observations.removeAll() }

    public func promptContext(at: Date = Date(), characterBudget: Int = 1600) -> String {
        let budget = max(0, min(characterBudget, 1600))
        var recent = observations.filter { at.timeIntervalSince($0.at) <= maximumAge && $0.at <= at }.map { observation in
            var compact = observation
            compact.title = String(compact.title.prefix(100))
            compact.summary = String(compact.summary.prefix(100))
            compact.excerpt = String(compact.excerpt.prefix(80))
            return compact
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while !recent.isEmpty {
            if let data = try? encoder.encode(recent), let json = String(data: data, encoding: .utf8), json.count <= budget {
                return json
            }
            recent.removeFirst()
        }
        return "[]"
    }
}
