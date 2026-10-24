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
        // 10/16: a LeetCode problem about order prices was called Math, twice, while SWE ran.
        if isLeetCodePractice(title: title) {
            return Decision(category: FocusCategories.leetCode, reason: "LeetCode or NeetCode interview practice", uncertain: false)
        }
        if isCodingPractice(title: title) {
            return Decision(category: "SWE", reason: "A coding practice site", uncertain: false)
        }
        // 10/16: an Apple Journal entry about a math midterm was called Math for 12 minutes.
        if isJournalApp(app: app) {
            return Decision(category: "Journaling", reason: "A journal app", uncertain: false)
        }
        // 10/14: New Tab and Focus's own block page were labeled Admin and drew cards.
        if isPlaceholderPage(app: app, title: title) {
            return Decision(category: nil, reason: "An empty tab or block page does not show the task", uncertain: true)
        }
        // 10/21: the YouTube home feed was AI because its recommendations listed deep-learning videos.
        if isYouTubeHome(title: title) {
            return Decision(category: "Leisure", reason: "The YouTube home feed", uncertain: false)
        }
        // 10/21: the model repeatedly called 3Blue1Brown's "Attention in transformers ·
        // Deep Learning Chapter 6" video Leisure, even with the attention equation visible.
        if supportsMLStudy(title: title, text: text) {
            return Decision(category: "AI", reason: "Visible ML/deep-learning study or research material", uncertain: false)
        }
        if category == "Reading", isVideo(title: title) {
            return Decision(category: nil, reason: "Reading means reading; a video needs a fresh label", uncertain: true)
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
            // 10/23: OpenAI's "Dreaming: Better memory for a more helpful ChatGPT" post was Admin mid-LeetCode.
            if category == "Admin", browsers.contains(normalized(app)), assistantBrands.contains(where: normalized(title).contains),
               !["billing", "account", "settings", "invoice", "api key", "usage"].contains(where: normalized(title).contains) {
                return Decision(category: nil, reason: "A page about an AI assistant is not an errand or Focus-project work", uncertain: true)
            }
            // 10/14: YouTube clips (SNL, tech interviews) were called Admin.
            if category == "Admin", isVideo(title: title) {
                return Decision(category: "Leisure", reason: "A video is not an errand", uncertain: false)
            }
            // 10/17: Amazon.jobs sign-up, a résumé upload in a job-application agent and a chat
            // about which internships to apply to were called Admin while Recruiting ran.
            if category == "Admin" || category == "SWE", showsJobApplication(title: title, text: category == "Admin" ? text : "") {
                return Decision(category: "Recruiting", reason: "A job or internship application", uncertain: false)
            }
            // 10/14: a Desktop folder list with course folders was called SWE.
            if normalized(app) == "finder" {
                return Decision(category: nil, reason: "A Finder folder lists files; it does not show the task", uncertain: true)
            }
            // 10/18: a Reminders list was Recruiting because its sidebar has lists named Recruiting and Networking.
            if normalized(app) == "reminders" {
                return Decision(category: nil, reason: "A to-do list names tasks; it does not show which one you're doing", uncertain: true)
            }
            // 10/19: a glance at Calendar and a Zoom window ("Upgrade to Zoom Pro") were Admin and drew two cards mid-AI.
            if normalized(app) == "calendar" {
                return Decision(category: nil, reason: "A calendar shows plans; it does not show what you're doing", uncertain: true)
            }
            if isVideoCall(app: app) {
                return Decision(category: nil, reason: "A call window does not show what the call is about", uncertain: true)
            }
            // 10/22: VS Code with no folder open, then a review of in-context-learning papers
            // (von_oswald_review.md beside paper PDFs), was SWE: "Code editor interface visible."
            if category == "SWE", isCodeEditor(app: app), !editsSourceFile(title: title) {
                return Decision(category: nil, reason: "A code editor without a source file open does not show coding", uncertain: true)
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
        // 10/18: a Google search "diff between a compiler and an assembler" during an
        // assembly pset was called Recruiting ("a common task in the recruiting category").
        if category == "Recruiting", source == .model, !supportsRecruiting(title: title, text: text) {
            return Decision(category: nil, reason: "Recruiting needs something about jobs, applications or recruiters on screen", uncertain: true)
        }
        if category == "Reading" {
            // 10/19: "nature machine intelligence - Google Search" was Reading.
            if isSearchResults(title: title) {
                return Decision(category: nil, reason: "Search results are not long-form reading", uncertain: true)
            }
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
        // 10/23: ChatGPT's home ("What should we work on?") lists its own suggestions
        // ("Your 3231 PSET 6 deadlines…"); the model called that Admin mid-LeetCode.
        let home = ["what should we work on", "what's on your mind", "where should we begin", "ready when you are",
                    "how can i help you today"]
        if home.contains(where: content.contains) { return true }
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
        // 10/18: "Logo ideas for Focus" / "Focus Logo Round 1" chats were SWE and drew six cards.
        let markers = ["focus app", "focus project", "focuscore", "screenwatcher.swift", "dashboardview.swift", "code/focus",
                       "focus logo", "focus icon", "focus-logo", "logo ideas for focus", "logo for focus", "icon for focus"]
        if title == "focus" || markers.contains(where: { title.contains($0) }) { return true }
        let development = ["improve", "build", "implement", "redesign", "refactor", "debug", "develop", "review the codebase",
                           "install", "settings", "configure", "roadmap", "category", "work on", "working on",
                           "logo", "icon", "menu bar"]
        // Marker and development word on one line: 10/23 a chat named "find focus app vision"
        // in ChatGPT's recents plus "What should we work on?" made three unrelated chats Admin.
        return body.components(separatedBy: "\n").contains { line in
            markers.contains(where: line.contains) && development.contains(where: line.contains)
        }
    }

    private static let assistantBrands = ["chatgpt", "openai", "claude", "anthropic", "codex"]

    public static func isLeetCodePractice(title: String, url: String? = nil) -> Bool {
        if let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }),
           ["leetcode.com", "neetcode.io"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        let title = normalized(String(title.prefix(240)))
        return ["leetcode", "neetcode"].contains { title == $0 || title.hasSuffix("- " + $0) || title.hasSuffix("| " + $0) }
    }

    public static func isCodingPractice(title: String, url: String? = nil) -> Bool {
        let title = normalized(String(title.prefix(240)))
        let sites = ["leetcode", "neetcode", "hackerrank", "codeforces", "codesignal", "atcoder"]
        if sites.contains(where: { title.hasSuffix("- \($0)") || title.hasSuffix("| \($0)") || title == $0 }) { return true }
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        return sites.contains { host == "\($0).com" || host == "\($0).io" || host.hasSuffix(".\($0).com") || host == "\($0).jp" }
    }

    public static func showsJobApplication(title: String, text: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        let titleMarks = [".jobs", "careers", "job search", "job application", "internship", "resume", "cover letter",
                          "greenhouse", "lever.co", "workday", "handshake", "simplify jobs", "linkedin jobs"]
        if titleMarks.contains(where: title.contains) || containsWordBeginning("jobs", in: title) && !title.contains("steve jobs") {
            return true
        }
        guard !title.contains("inbox") else { return false }
        let body = normalized(String(text.prefix(2400)))
        let bodyMarks = ["job application", "internship", "greenhouse.io", "lever.co", "myworkdayjobs", "amazonjobs", "amazon.jobs",
                         "upload resume", "uploading resume", "upload your resume", "cover letter", "apply now",
                         "submit application", "applied to", "recruiter", "careers page"]
        return bodyMarks.filter(body.contains).count >= 2
    }

    public static func supportsRecruiting(title: String, text: String) -> Bool {
        if showsJobApplication(title: title, text: text) { return true }
        let page = normalized(String(title.prefix(240))) + " " + normalized(String(text.prefix(2400)))
        let marks = ["linkedin", "handshake", "glassdoor", "levels.fyi", "recruit", "internship", "job posting", "job offer",
                     "offer letter", "hiring", "careers", "resume", "cover letter", "application status", "apply now",
                     "applied to", "networking", "coffee chat", "superday", "onsite interview", "phone screen"]
        return marks.contains(where: page.contains) || containsWordBeginning("jobs", in: page)
    }

    public static func isJournalApp(app: String, bundle: String = "") -> Bool {
        ["com.apple.journal", "com.bloombuilt.dayone-mac"].contains(bundle.lowercased())
            || ["journal", "day one"].contains(normalized(app))
    }

    public static func isSocialFeed(title: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        return ["• threads", "• instagram", "instagram photos", "tiktok", "facebook"].contains { title.contains($0) }
            || title.hasSuffix("instagram") || title.hasSuffix(" / x")
    }

    public static func isVideo(title: String) -> Bool {
        let title = normalized(String(title.prefix(240))).trimmingCharacters(in: CharacterSet.alphanumerics.union(.punctuationCharacters).inverted)
        return title.hasSuffix("- youtube") || isYouTubeHome(title: title)
    }

    public static func isYouTubeHome(title: String) -> Bool {
        let title = normalized(String(title.prefix(240))).trimmingCharacters(in: CharacterSet.alphanumerics.union(.punctuationCharacters).inverted)
        return title.range(of: #"^(\(\d+\+?\) )?youtube$"#, options: .regularExpression) != nil
    }

    // 10/21: career questions in an ML paper chat ("what research would Meta Superintelligence Labs
    // find most employable", "ML research pay outlook") were AI and drew six cards; all kept Leisure.
    private static func showsCareerTalk(_ page: String) -> Bool {
        let marks = ["employable", "hiring", "levels.fyi", "new-grad", "new grad", "salary", "salaries", "compensation",
                     "job offer", "full-time offer", "recruiter", "pay outlook", "total comp", "interview loop"]
        return marks.filter(page.contains).count >= 2
    }

    public static func isSearchResults(title: String) -> Bool {
        let title = normalized(String(title.prefix(240)))
        return ["- google search", "- bing", "at duckduckgo", "- search", "- perplexity"].contains { title.hasSuffix($0) }
    }

    public static func isVideoCall(app: String) -> Bool {
        ["zoom", "zoom.us", "zoom workplace", "facetime", "microsoft teams", "webex"].contains(normalized(app))
    }

    public static func isCodeEditor(app: String) -> Bool {
        ["code", "visual studio code", "cursor", "zed", "sublime text", "windsurf", "nova", "bbedit"].contains(normalized(app))
    }

    /// Editors title windows "file — workspace"; a bare workspace, the app name or a
    /// prose document (notes, a paper, a review) is not source code.
    public static func editsSourceFile(title: String) -> Bool {
        let file = normalized(title).components(separatedBy: " — ").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "● ").union(.whitespaces)) ?? ""
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return false }
        let ext = String(file[file.index(after: dot)...])
        guard !ext.isEmpty, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return !["md", "markdown", "txt", "rtf", "pdf", "docx", "doc", "tex", "bib", "csv", "log"].contains(ext)
    }

    private static let browsers = ["google chrome", "safari", "arc", "firefox", "microsoft edge", "brave browser", "chromium"]

    public static func isPlaceholderPage(app: String, title: String) -> Bool {
        guard browsers.contains(normalized(app)) else { return false }
        let title = normalized(title).trimmingCharacters(in: .whitespaces)
        if ["", "new tab", "new incognito tab", "new private tab", "start page", "untitled", "blocked · focus"].contains(title) { return true }
        // 10/18: Canvas and Yale CAS sign-in pages were Admin and drew a card on the way to coursework.
        return title.range(of: #"^(?:log ?in|sign ?in|central authentication service)(?:$|\s*[-|:·])"#, options: .regularExpression) != nil
            || title.hasSuffix("- sign in") || title.hasSuffix("| sign in")
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
        let body = normalized(String(text.prefix(2400))).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let domains = ["machine learning", "deep learning", "neural network", "backpropagation", "transformer",
                       "gradient descent", "self attention", "self-attention", "transformer architecture",
                       "convolutional network", "reinforcement learning", "loss function", "language model training",
                       "diffusion model", "variational autoencoder", "generative adversarial network",
                       "support vector machine", "random forest", "supervised learning", "unsupervised learning",
                       "attention mechanism", "large language model", "representation learning", "contrastive learning",
                       "recurrent neural network", "policy gradient", "q-learning", "stochastic gradient",
                       "in-context learning", "meta-learning", "metalearning", "linear attention", "linear-attention", "pretraining",
                       "chain-of-thought", "chain of thought", "latent reasoning", "interpretability", "mech interp",
                       "hidden states", "scaling law", "rlhf", "fine-tuning", "next-token prediction", "scalable oversight",
                       "sequence model", "state space model", "few-shot learning", "catastrophic forgetting",
                       "multilayer perceptron", "weights and biases", "deltanet", "delta rule", "delta-rule",
                       "fast weight", "fast-weight", "kv cache", "mixture of experts", "mixture-of-experts"]
        let study = ["learn", "study", "research", "paper", "lecture", "tutorial", "derive", "derivation",
                     "explain", "understand", "notes", "course", "experiment", "implement", "train", "introduction"]
        let meta = ["focus app", "focuscore", "screen tracking", "screen watcher", "screenwatcher",
                    "activity tracking", "activity classifier", "classification policy", "dashboard",
                    "ai category", "ai means", "category means"]
        let titleWords = title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let titleHasDomain = domains.contains { title.contains($0) } || titleWords.contains("llm") || titleWords.contains("llms")
        let titleIsMeta = meta.contains { title.contains($0) }
        let transformerAttentionTitle = ["attention in transformer", "transformer attention", "multi-head attention", "multihead attention"]
            .contains { title.contains($0) }
        let knownMLCourseTitle = title.range(of: #"\bcpsc\s*7770\b"#, options: .regularExpression) != nil
        let learningChapterTitle = title.range(
            of: #"(?:deep |machine )?learning chapter [0-9]+|(?:…|\.\.\.)earning chapter [0-9]+"#,
            options: .regularExpression
        ) != nil
        if (transformerAttentionTitle || knownMLCourseTitle || learningChapterTitle) && !titleIsMeta { return true }
        let subjectQuestion = title.range(
            of: #"^(?:\([0-9]+\+?\)\s*)?(?:what is|how does|how do|how might|why)\b"#,
            options: .regularExpression
        ) != nil
        if titleHasDomain && !titleIsMeta && (domains.contains(title) || subjectQuestion || study.contains(where: { containsWordBeginning($0, in: title) })) {
            return true
        }
        if title == "attention is all you need" || title.hasPrefix("attention is all you need (") {
            return true
        }
        // A tracker discussing its model is evidence about building the tracker,
        // even when the discussion quotes the definition of the AI category.
        guard !meta.contains(where: { title.contains($0) || body.contains($0) }) else { return false }
        guard !showsCareerTalk(title + " " + body) else { return false }
        let hasStudyEvidence = study.contains { containsWordBeginning($0, in: title + " " + body) }
        let strongBodyDomain = ["softmax attention", "linear attention", "linear-attention", "self attention", "self-attention",
                                "multi-head attention", "multihead attention", "attention mechanism", "transformer architecture"]
            .contains { body.contains($0) }
            || body.contains("softmax") && body.contains("attention")
        if strongBodyDomain && hasStudyEvidence { return true }
        let keyValueMemoryStudy = body.contains("outer product") && body.contains("memory")
            && containsWordBeginning("key", in: body) && containsWordBeginning("value", in: body)
        if keyValueMemoryStudy && hasStudyEvidence { return true }
        let bodyWords = body.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let abbreviatedHits = ["relu", "mlp"].filter { bodyWords.contains($0) }.count
        // 10/21: the CPSC 7770 Canvas Files page ("Advanced Topics in Deep Learning") was Math.
        let courseHit = body.range(of: #"\bcpsc\s*7770\b"#, options: .regularExpression) != nil ? 1 : 0
        let hits = domains.filter { body.contains($0) }.count + abbreviatedHits + courseHit
        return hits >= 2 && hasStudyEvidence
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
