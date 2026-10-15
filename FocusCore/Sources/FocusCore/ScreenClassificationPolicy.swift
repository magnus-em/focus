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
        if category == "Reading", let alternative = readingAlternative(title: title) {
            return source == .model
                ? Decision(category: alternative, reason: "Reading is educational long-form material; this shows browsing or an errand", uncertain: false)
                : Decision(category: nil, reason: "Earlier Reading label conflicts with the visible browsing or errand; needs a fresh label", uncertain: true)
        }
        if source == .model {
            // 10/14: the model called Threads and Instagram feeds Admin and Reading.
            if isSocialFeed(title: title), category != nil, category != "Leisure" {
                return Decision(category: "Leisure", reason: "A social media feed", uncertain: false)
            }
            if category == "Math", showsMaterialCuriosity(title: title, text: text) {
                return supportsEducationalReading(title: title, text: text)
                    ? Decision(category: "Reading", reason: "An educational explainer, without mathematics or coursework", uncertain: false)
                    : Decision(category: nil, reason: "Curiosity alone does not establish coursework or educational long-form reading", uncertain: true)
            }
        }
        guard let category else {
            return Decision(category: nil, reason: "Not enough evidence to identify the task", uncertain: true)
        }
        if category == "Reading" {
            if source == .model && !supportsEducationalReading(title: title, text: text) {
                return Decision(category: nil, reason: "Not enough evidence of an educational article, book, paper or substantial explainer", uncertain: true)
            }
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

    public static func isSocialFeed(title: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        return ["• threads", "• instagram", "instagram photos", "tiktok", "facebook"].contains { title.contains($0) }
            || title.hasSuffix("instagram") || title.hasSuffix(" / x")
    }

    public static func readingAlternative(title: String) -> String? {
        let title = normalized(String(title.prefix(240)))
        if ["pay bill", "bill payment", "tax form", "account settings", "appointment booking", "course registration"].contains(where: title.contains) {
            return "Admin"
        }
        if isSocialFeed(title: title)
            || ["breaking news", "latest news", "top stories", "hacker news", "shopping cart", "shop online", "amazon.com", "ebay.com"].contains(where: title.contains)
            || title.hasSuffix(" - reddit") || title.hasSuffix(" | reddit") || title.hasPrefix("r/")
            || title.range(of: #"^(?:news|home feed|for you|shopping|forums?)(?:$|\s*[-|:])"#, options: .regularExpression) != nil {
            return "Leisure"
        }
        return nil
    }

    public static func supportsEducationalReading(title: String, text: String) -> Bool {
        guard readingAlternative(title: title) == nil else { return false }
        let title = normalized(String(title.prefix(240)))
        let body = normalized(String(text.prefix(2400)))
        let explicit = ["textbook", "documentation", "tutorial", "beginner's guide", "beginners guide",
                        "introduction to", "explainer", "lecture notes", "understanding "]
        if explicit.contains(where: title.contains) { return true }
        let form = ["article", "essay", "chapter", "book", "paper", "journal", "read online", "epub"]
        let subject = ["learn", "explain", "concept", "history", "science", "psychology", "philosophy",
                       "economics", "biology", "physics", "engineering", "mathematics", "research", "evidence"]
        let content = title + "\n" + body
        if form.contains(where: { containsWordBeginning($0, in: content) }),
           subject.contains(where: { containsWordBeginning($0, in: content) }) { return true }
        let explanations = ["because ", "for example", "in other words", "defined as", "refers to", "means that"]
        return body.count >= 800 && explanations.filter(body.contains).count >= 2
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
