import AppKit
import FoundationModels
import FocusCore
import ScreenCaptureKit
import Vision

/// What the frontmost window showed over a stretch of time. Device-local;
/// screenshots and recognized text are never stored, only title + summary.
struct ScreenSpan: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date
    var app: String
    var bundleID: String
    var title: String
    var summary: String
    var category: String?
    var id: Date { start }
}

/// Every 15s (and on every app switch) while you're at the Mac: capture the frontmost window, read it
/// with Vision, label it (your past choices first, then the on-device Apple
/// Intelligence model), and let `ScreenCoach` suggest a backdated switch.
@MainActor
final class ScreenWatcher: ObservableObject {
    static let shared = ScreenWatcher()

    @Published private(set) var spans: [ScreenSpan] = []
    @Published private(set) var status = "Off"

    static let interval: TimeInterval = 15
    private static let keepDays = 30
    /// Never captured; logged as "Private".
    static let privateApps: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.MobileSMS", "com.apple.mail",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.dashlane.dashlanephonefinal",
        "org.torproject.torbrowser", "com.apple.FaceTime",
    ]
    private static let ignoredApps: Set<String> = [
        "com.magnus.focus", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ]

    var onSample: ((ScreenSample) -> Void)?
    private(set) var samples: [ScreenSample] = []
    private var settings: AppSettings?
    private var tick: Timer?
    private var busy = false
    private var cache: [String: (category: String?, summary: String)] = [:]
    private var unsavedSamples = 0
    private var lastSampleAt = Date.distantPast
    private var activationObserver: NSObjectProtocol?
    /// Model-written task names for activity blocks, keyed by block start.
    @Published private(set) var activityNames: [Date: ActivityName] = [:]
    private var naming = false

    struct ActivityName: Codable {
        var name: String
        var spanCount: Int
        var at: Date
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screen.json")
    }()

    private var namesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("screen-activities.json") }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ScreenSpan].self, from: data) {
            spans = saved
        }
        if let data = try? Data(contentsOf: namesURL),
           let saved = try? JSONDecoder().decode([Date: ActivityName].self, from: data) {
            activityNames = saved
        }
    }

    func start(settings: AppSettings) {
        self.settings = settings
        guard tick == nil else { return }
        if settings.screenWatch, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        tick = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        // Catch app switches right away instead of waiting for the next tick.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    guard let self, Date().timeIntervalSince(self.lastSampleAt) > 3 else { return }
                    await self.sample()
                }
            }
        }
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func spans(from: Date, to: Date) -> [ScreenSpan] {
        spans.filter { $0.end > from && $0.start < to }
    }

    static var modelAvailable: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    // MARK: - Sampling

    private func sample() async {
        guard let settings, settings.screenWatch else { status = "Off"; return }
        guard !busy else { return }
        guard !PresenceMonitor.shared.isAway else { status = "Paused while you're away"; return }
        guard CGPreflightScreenCaptureAccess() else { status = "Needs Screen Recording permission"; return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !Self.ignoredApps.contains(bundle) else { return }
        let appName = app.localizedName ?? bundle
        let now = Date()

        if Self.privateApps.contains(bundle) {
            record(ScreenSample(date: now, app: appName, bundleID: bundle, title: "", summary: "Private", category: nil))
            return
        }

        busy = true
        lastSampleAt = now
        defer { busy = false }
        guard let shot = await Self.captureFrontWindow(pid: app.processIdentifier) else { return }
        let text = await Task.detached(priority: .utility) { Self.recognizeText(shot.image) }.value
        let (category, summary) = await classify(app: appName, bundle: bundle, title: shot.title, text: text)
        status = Self.modelAvailable ? "Watching" : "Watching · Apple Intelligence off, learning from your choices only"
        record(ScreenSample(date: now, app: appName, bundleID: bundle, title: shot.title,
                            summary: summary, category: category))
    }

    private func record(_ s: ScreenSample) {
        samples.append(s)
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }

        let end = s.date.addingTimeInterval(Self.interval)
        if var last = spans.last, last.bundleID == s.bundleID, last.title == s.title, last.category == s.category,
           s.date.timeIntervalSince(last.end) < Self.interval {
            last.end = end
            last.summary = s.summary
            spans[spans.count - 1] = last
        } else {
            if let last = spans.last, last.end > s.date { spans[spans.count - 1].end = s.date }
            spans.append(ScreenSpan(start: s.date, end: end, app: s.app, bundleID: s.bundleID,
                                    title: s.title, summary: s.summary, category: s.category))
        }
        unsavedSamples += 1
        if unsavedSamples >= 4 { save() }
        onSample?(s)
        Task { await nameNextActivity() }
    }

    func save() {
        unsavedSamples = 0
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86400)
        spans.removeAll { $0.end < cutoff }
        if let data = try? JSONEncoder().encode(spans) { try? data.write(to: fileURL, options: .atomic) }
        activityNames = activityNames.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(activityNames) { try? data.write(to: namesURL, options: .atomic) }
    }

    // MARK: - Activities

    /// Spans grouped into stretches of one kind of work. Blips under a minute
    /// between two spans of the same category don't split a block.
    func activities(from: Date, to: Date) -> [ScreenActivity] {
        let list = spans(from: from, to: to).sorted { $0.start < $1.start }
        var smoothed = list.map(\.category)
        if list.count >= 3 {
            for i in 1..<(list.count - 1) {
                let d = list[i].end.timeIntervalSince(list[i].start)
                if d < 60, smoothed[i - 1] == smoothed[i + 1], smoothed[i] != smoothed[i - 1] { smoothed[i] = smoothed[i - 1] }
            }
        }
        var out: [ScreenActivity] = []
        for (i, span) in list.enumerated() {
            let c = smoothed[i]
            if var last = out.last, last.category == c, span.start.timeIntervalSince(last.end) < 5 * 60 {
                last.end = max(last.end, span.end)
                last.spans.append(span)
                out[out.count - 1] = last
            } else {
                out.append(ScreenActivity(start: span.start, end: span.end, category: c, spans: [span]))
            }
        }
        return out
    }

    func name(for a: ScreenActivity) -> String {
        activityNames[a.start]?.name ?? a.topTitle
    }

    /// Names one block per sample: the live one as it grows, then any unnamed.
    private func nameNextActivity() async {
        guard !naming, #available(macOS 26.0, *), Self.modelAvailable else { return }
        let now = Date()
        let blocks = activities(from: now.addingTimeInterval(-36 * 3600), to: now)
            .filter { $0.category != nil && $0.end.timeIntervalSince($0.start) >= 120 }
        let stale = blocks.reversed().first { b in
            guard let n = activityNames[b.start] else { return true }
            return Double(b.spans.count) >= Double(n.spanCount) * 1.25 && now.timeIntervalSince(n.at) > 120
        }
        guard let b = stale else { return }
        naming = true
        defer { naming = false }
        if let name = await ScreenModel.nameActivity(category: b.category ?? "", summaries: b.distinctSummaries,
                                                     titles: b.distinctTitles) {
            activityNames[b.start] = ActivityName(name: name, spanCount: b.spans.count, at: now)
        }
    }

    // MARK: - Capture + OCR

    private struct Shot: @unchecked Sendable {
        let image: CGImage
        let title: String
    }

    private static func captureFrontWindow(pid: pid_t) async -> Shot? {
        // CGWindowList is front-to-back; SCShareableContent isn't ordered.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let front = info.first { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) > 200 && (b["Height"] ?? 0) > 150
        }
        guard let id = front?[kCGWindowNumber as String] as? CGWindowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }

        let config = SCStreamConfiguration()
        let scale = min(2, 2400 / max(window.frame.width, window.frame.height))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
        ) else { return nil }
        return Shot(image: image, title: window.title ?? (front?[kCGWindowName as String] as? String) ?? "")
    }

    nonisolated private static func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(1500))
    }

    // MARK: - Classification

    nonisolated static func memoryKey(bundle: String, title: String) -> String {
        bundle + "|" + title.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static let memoryDefaultsKey = "screenMemory"

    static var memory: [String: String] {
        UserDefaults.standard.dictionary(forKey: memoryDefaultsKey) as? [String: String] ?? [:]
    }

    /// The user's answer for these windows beats the model next time.
    static func learn(_ keys: Set<String>, as category: String) {
        var m = memory
        for k in keys { m[k] = category }
        if m.count > 800 { m = Dictionary(uniqueKeysWithValues: m.shuffled().prefix(800).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(m, forKey: memoryDefaultsKey)
    }

    private func classify(app: String, bundle: String, title: String, text: String) async -> (String?, String) {
        let fallbackSummary = title.isEmpty ? app : "\(app): \(title)"
        let candidates = candidateCategories()
        if let known = Self.memory[Self.memoryKey(bundle: bundle, title: title)], candidates.contains(known) {
            return (known, cache[cacheKey(bundle, title, text)]?.summary ?? fallbackSummary)
        }
        let key = cacheKey(bundle, title, text)
        if let hit = cache[key] { return hit }
        guard #available(macOS 26.0, *), Self.modelAvailable, !text.isEmpty || !title.isEmpty else {
            return (nil, fallbackSummary)
        }
        let result = await ScreenModel.classify(app: app, title: title, text: text, categories: candidates)
            ?? (nil, fallbackSummary)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private func cacheKey(_ bundle: String, _ title: String, _ text: String) -> String {
        "\(bundle)|\(title)|\(text.prefix(300).hashValue)"
    }

    /// Categories you could plausibly be doing on a screen.
    private func candidateCategories() -> [String] {
        let offScreen: Set<String> = ["Sleep", "Meals", "Exercise", "Commute", "Chores"]
        return (settings?.tags ?? []).filter { !offScreen.contains($0) }
    }
}

struct ScreenActivity: Identifiable {
    var start: Date
    var end: Date
    var category: String?
    var spans: [ScreenSpan]
    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }

    private func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for v in values where !v.isEmpty { counts[v, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
    var distinctSummaries: [String] { Array(ranked(spans.map(\.summary)).prefix(10)) }
    var distinctTitles: [String] { Array(ranked(spans.map { $0.title.isEmpty ? $0.app : "\($0.app): \($0.title)" }).prefix(6)) }
    var apps: [String] { ranked(spans.map(\.app)) }
    var topTitle: String { distinctTitles.first ?? "Unknown" }
}

struct ScreenSample {
    let date: Date
    let app: String
    let bundleID: String
    let title: String
    let summary: String
    let category: String?
    var memoryKey: String { ScreenWatcher.memoryKey(bundle: bundleID, title: title) }
}

@available(macOS 26.0, *)
private enum ScreenModel {
    /// Tuned against the 3B on-device model: without these it calls a discrete
    /// math problem set "Reading".
    static let hints: [String: String] = [
        "Math": "mathematics work: proofs, theorems, discrete math, graphs, combinatorics, math problem sets and lectures",
        "HW": "homework for non-math classes: essays, assigned readings, econ or history problem sets",
        "SWE": "coding interview prep: LeetCode, NeetCode, algorithm practice",
        "Quant": "quant interview prep: probability puzzles, brainteasers, mental math, QuantGuide",
        "AI": "building AI/ML projects, coding projects with AI tools",
        "Reading": "reading books or articles, or exploring ideas with an AI chat, for personal curiosity, not for a class",
        "Leisure": "entertainment: YouTube, streaming, games, social feeds",
        "Admin": "email, forms, calendars, settings, errands online",
        "Class": "attending a live lecture or class call",
        "Social": "chatting with friends",
    ]

    static func nameActivity(category: String, summaries: [String], titles: [String]) async -> String? {
        let prompt = """
        Category: \(category)
        Windows: \(titles.joined(separator: "; "))
        Moment-to-moment notes: \(summaries.joined(separator: "; "))
        """
        let session = LanguageModelSession(instructions: """
        Name the task a student was working on during this stretch, using only the windows and notes given. \
        Under 10 words: the subject, document, problem or project actually named there. Never add details that aren't in the input. No ending period.
        """)
        guard let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0)) else { return nil }
        let line = r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"."))).components(separatedBy: "\n").first ?? ""
        return line.isEmpty ? nil : String(line.prefix(80))
    }

    static func classify(app: String, title: String, text: String, categories: [String]) async -> (String?, String)? {
        let lines = categories.map { c in hints[c].map { "- \(c): \($0)" } ?? "- \(c)" }
        let instructions = """
        You label what a student is doing on their Mac from the frontmost window's app, title and on-screen text. Pick the single best category.
        \(lines.joined(separator: "\n"))
        - Unclear: not enough information.
        Coursework and problem sets are never Reading.
        """
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Guess", properties: [
                .init(name: "summary", description: "What is on this screen, under 12 words, using names and topics visible in the text. Don't repeat the category descriptions.",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "category", schema: DynamicGenerationSchema(name: "Category", anyOf: categories + ["Unclear"])),
            ]), dependencies: [])
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: "App: \(app)\nWindow: \(title)\nScreen text: \(text)",
                                              schema: schema, options: GenerationOptions(temperature: 0))
            let category = try r.content.value(String.self, forProperty: "category")
            let summary = try r.content.value(String.self, forProperty: "summary")
            return (categories.contains(category) ? category : nil, summary)
        } catch {
            return nil
        }
    }
}

// MARK: - Suggestions

/// Suggests switching when the screen has shown another category for a few
/// minutes, backdated to when it started. Never switches on its own.
@MainActor
final class ScreenCoach {
    nonisolated(unsafe) static var shared: ScreenCoach?

    private let watcher = ScreenWatcher.shared
    private let timer: TimerManager
    private let settings: AppSettings
    private let days: DayStore
    private let panel = AwayPanel()
    private var snoozed: [String: Date] = [:]

    static let acceptedKey = "screenSuggest.accepted"
    static let declinedKey = "screenSuggest.declined"

    init(timer: TimerManager, settings: AppSettings, days: DayStore) {
        self.timer = timer
        self.settings = settings
        self.days = days
        watcher.onSample = { [weak self] _ in self?.consider() }
        watcher.start(settings: settings)
    }

    /// AwayCoach checks this from main-thread timers that aren't actor-annotated.
    nonisolated var isBusy: Bool { MainActor.assumeIsolated { panel.isBusy } }

    private struct Run {
        let category: String
        let start: Date
        let keys: Set<String>
        let summary: String
    }

    /// Trailing stretch where ≥ 80% of samples say the same category; two
    /// misses in a row or a 3-minute hole ends it.
    private func trailingRun() -> Run? {
        let samples = watcher.samples
        guard let last = samples.last, let c = last.category else { return nil }
        var start = last.date, hits = 0, total = 0, missStreak = 0
        var keys: Set<String> = []
        var newer = last.date
        for s in samples.reversed() {
            if newer.timeIntervalSince(s.date) > 180 { break }
            newer = s.date
            total += 1
            if s.category == c {
                hits += 1; missStreak = 0; start = s.date; keys.insert(s.memoryKey)
            } else {
                missStreak += 1
                if missStreak >= 2 { total -= 2; break }
            }
        }
        guard hits >= 4, Double(hits) / Double(max(total, 1)) >= 0.8,
              last.date.timeIntervalSince(start) >= Double(settings.screenSuggestMinutes) * 60 else { return nil }
        return Run(category: c, start: start, keys: keys, summary: last.summary)
    }

    private func consider() {
        guard settings.screenSuggest, days.isDayStarted, !panel.isBusy,
              !(AwayCoach.shared?.isBusy ?? false), let run = trailingRun() else { return }
        if timer.isActive && !timer.isRunning { return }
        let running: String? = timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : nil
        guard running != run.category, (snoozed[run.category] ?? .distantPast) < Date() else { return }

        let minutes = Date().timeIntervalSince(run.start) / 60
        let m = AwayPromptModel(
            icon: "eye",
            title: "Looks like \(run.category)",
            subtitle: "since \(run.start.formatted(date: .omitted, time: .shortened)) · \(Int(minutes))m on screen",
            question: run.summary,
            keep: running.map { "Still \($0)" },
            options: [run.category], tags: settings.tags
        )
        m.onPick = { [weak self] label in
            guard let self else { return }
            if let label {
                self.timer.switchTo(label, at: run.start)
                ScreenWatcher.learn(run.keys, as: label)
            } else {
                self.timer.startManualBreak(minutes: 0, at: run.start)
            }
            Self.bump(Self.acceptedKey)
            self.panel.dismiss()
        }
        m.onKeep = { [weak self] in
            guard let self else { return }
            if let running, running != "Break" { ScreenWatcher.learn(run.keys, as: running) }
            self.decline(run.category)
        }
        panel.show(m)
        let close = m.onClose
        m.onClose = { [weak self] in
            self?.decline(run.category)
            close?()
        }
    }

    private func decline(_ category: String) {
        snoozed[category] = Date().addingTimeInterval(20 * 60)
        Self.bump(Self.declinedKey)
        panel.dismiss()
    }

    private static func bump(_ key: String) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}
