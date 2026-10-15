import Foundation
import FocusCore

/// Writes a day's coach record (`Focus/days/DATE.json`) once: for yesterday
/// after 4 AM, or as soon as the morning recall asks. Input is the tracked
/// log, the screen's activity blocks with their notes, and up to eight
/// screenshots of study time. A browser window counts only when the journal
/// confirmed it wasn't private; otherwise its title, notes and screenshots
/// are withheld.
@MainActor
final class CoachDayWorker: ObservableObject {
    static let shared = CoachDayWorker()

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/days", isDirectory: true)
    static let calibrationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/coach/calibration.jsonl")
    static let examsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/coach/exams.jsonl")
    nonisolated private static let journalDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/journal", isDirectory: true)
    private static let evidenceDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/screen-evidence", isDirectory: true)
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]

    enum Status: Equatable { case working, failed(String) }

    @Published private(set) var records: [String: CoachDay.Record] = [:]
    @Published private(set) var status: [String: Status] = [:]
    private var lastAttempt: [String: Date] = [:]
    private weak var store: SessionStore?
    private weak var days: DayStore?
    private weak var settings: AppSettings?
    private var timer: Timer?

    var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    }

    func start(store: SessionStore, days: DayStore, settings: AppSettings) {
        self.store = store
        self.days = days
        self.settings = settings
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            await self?.backfill()
        }
    }

    /// Yesterday, then the five days before it, one at a time, so the chat and
    /// the weekly review have history. Days with nothing logged are skipped.
    private func backfill() async {
        guard Calendar.current.component(.hour, from: Date()) >= 4 else { return }
        for offset in 1...6 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date())),
                  let client = Coach.client else { return }
            load(day)
            let key = CoachDay.dayKey(day)
            guard records[key] == nil || isPartial(day), status[key] != .working,
                  Date().timeIntervalSince(lastAttempt[key] ?? .distantPast) > 3600 else { continue }
            lastAttempt[key] = Date()
            status[key] = .working
            await generate(day, client: client)
            if case .failed(let why) = status[key], why.contains("budget") { return }
        }
    }

    func recentRecords(days: Int) -> [CoachDay.Record] {
        (1...days).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: -offset, to: Calendar.current.startOfDay(for: Date()))
        }.compactMap { day in
            load(day)
            return record(for: day)
        }
    }

    /// Today's evidence so far as text (no screenshots), for the chat.
    func todayEvidence() async -> String? {
        guard let (pack, _) = await buildPack(Date(), includeImages: false) else { return nil }
        return CoachDay.evidence(pack)
    }

    private func tick() {
        guard Calendar.current.component(.hour, from: Date()) >= 4 else { return }
        ensure(yesterday)
    }

    /// The saved record, if there is one; reads the file on first use.
    func record(for day: Date) -> CoachDay.Record? {
        records[CoachDay.dayKey(day)]
    }

    func load(_ day: Date) {
        let key = CoachDay.dayKey(day)
        if records[key] == nil, let r = CoachDay.load(day, from: Self.directory) { records[key] = r }
    }

    /// Written before the day was over (on demand), so the full day still needs one.
    private func isPartial(_ day: Date) -> Bool {
        guard let r = records[CoachDay.dayKey(day)],
              let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))
        else { return false }
        return r.generatedAt < next
    }

    /// Writes the record unless it exists for the whole day, is being written,
    /// failed in the last hour, or the cloud coach is off.
    func ensure(_ day: Date, force: Bool = false) {
        load(day)
        let key = CoachDay.dayKey(day)
        if force { lastAttempt[key] = nil }
        let over = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day)).map { Date() >= $0 } ?? false
        guard records[key] == nil || force || (isPartial(day) && over), status[key] != .working,
              Date().timeIntervalSince(lastAttempt[key] ?? .distantPast) > 3600,
              let client = Coach.client, store != nil else { return }
        lastAttempt[key] = Date()
        status[key] = .working
        Task { await generate(day, client: client) }
    }

    private func generate(_ day: Date, client: XAIClient) async {
        let key = CoachDay.dayKey(day)
        do {
            guard let (pack, images) = await buildPack(day) else {
                status[key] = .failed("Nothing was logged that day.")
                return
            }
            let text = CoachDay.prompt(pack)
            let model = XAIClient.Model.strong
            let estimate = XAIClient.estimateUSD(model: model, text: CoachDay.system + text, images: images.count,
                                                 maxOutputTokens: 16000, reasoningEffort: "low")
            let reply = try await Coach.budget.run(estimateUSD: estimate, model: model, purpose: "day \(key)") {
                try await client.complete(model: model, system: CoachDay.system, text: text, images: images,
                                          schema: CoachDay.schema, reasoningEffort: "low", maxOutputTokens: 16000,
                                          timeout: 600)
            }
            let record = CoachDay.Record(day: key, content: try CoachDay.content(from: reply.json), generatedAt: Date(),
                                         model: reply.model, costUSD: reply.usage.costUSD, images: images.count,
                                         promptVersion: CoachDay.promptVersion)
            try CoachDay.save(record, to: Self.directory)
            records[key] = record
            status[key] = nil
        } catch {
            status[key] = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case XAIClient.Failure.overBudget(let spent, let cap):
            return String(format: "Today's cloud budget is used up ($%.2f of $%.2f).", spent, cap)
        case XAIClient.Failure.http(let status, let message): return "xAI error \(status): \(message)"
        case XAIClient.Failure.malformed: return "The model's reply couldn't be read."
        case CoachBudget.Problem.ledgerUnreadable, CoachBudget.Problem.ledgerUnwritable:
            return "The spend ledger couldn't be read or written, so nothing was sent."
        default: return error.localizedDescription
        }
    }

    // MARK: - Evidence

    private struct JournalFacts: Sendable {
        /// "bundle|title" seen in a confirmed non-private browser window.
        var verified: Set<String> = []
        /// "bundle|title" seen in a private or unconfirmed one.
        var unverified: Set<String> = []
        var eligibleImages: Set<UUID> = []
    }

    private func buildPack(_ day: Date, includeImages: Bool = true) async -> (CoachDay.Pack, [Data])? {
        guard let store, let settings else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let focus = Set(settings.tags).subtracting(settings.lifeTags)
        let facts = await Task.detached { Self.journalFacts(for: day) }.value

        let now = Date()
        func session(_ s: WorkSession) -> CoachDay.Session {
            CoachDay.Session(start: s.startTime, end: s.startTime.addingTimeInterval(s.durationMinutes * 60),
                             label: s.type != .work ? "Break" : (s.label ?? "Focus"))
        }
        let saved = store.sessions
            .filter { $0.startTime < end && $0.startTime.addingTimeInterval($0.durationMinutes * 60) > start }
            .map(session)
        let live = QuickSwitch.shared?.inProgress.map(session).flatMap { $0.start < end && now > start ? $0 : nil }
        let sessions = CoachDay.trackedSessions(saved: saved, running: live, now: now)
        func tracked(_ a: Date, _ b: Date) -> String? {
            var overlap: [String: TimeInterval] = [:]
            for s in sessions {
                let o = min(b, s.end).timeIntervalSince(max(a, s.start))
                if o > 0 { overlap[s.label, default: 0] += o }
            }
            return overlap.max { $0.value < $1.value }?.key
        }
        func allowed(_ bundle: String, _ title: String) -> Bool {
            guard Self.browsers.contains(bundle) else { return true }
            let k = bundle + "|" + title
            return facts.verified.contains(k) && !facts.unverified.contains(k)
        }

        let watcher = ScreenWatcher.shared
        let blocks: [CoachDay.Block] = watcher.activities(from: start, to: end).compactMap { a in
            guard a.minutes >= 1 else { return nil }
            var windows: [String: Double] = [:]
            var hidden = false
            for s in a.spans {
                let ok = allowed(s.bundleID, s.title)
                hidden = hidden || !ok
                let name = ok ? (s.title.isEmpty ? s.app : "\(s.app): \(s.title)") : "\(s.app): unverified browser window"
                windows[name, default: 0] += s.end.timeIntervalSince(s.start) / 60
            }
            let notes = hidden ? [] : (watcher.notes(for: a)?.bullets ?? [])
            return CoachDay.Block(start: a.start, end: a.end, screenCategory: a.category, tracked: tracked(a.start, a.end),
                                  windows: windows.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                                  bullets: notes)
        }
        guard !sessions.isEmpty || !blocks.isEmpty else { return nil }

        // Up to eight screenshots of focus time, distinct windows, spread over the day.
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var seen = Set<String>()
        let candidates = (includeImages ? await ScreenEvidenceStore.shared.entries(from: start, to: end) : [])
            .sorted { $0.at < $1.at }.filter { e in
            guard let t = tracked(e.at, e.at.addingTimeInterval(15)), focus.contains(t),
                  !Self.browsers.contains(e.bundle) || facts.eligibleImages.contains(e.id) else { return false }
            return seen.insert(String(e.title.prefix(30))).inserted
        }
        let step = max(1, candidates.count / 8)
        var images: [Data] = []
        var labels: [String] = []
        for e in stride(from: 0, to: candidates.count, by: step).map({ candidates[$0] }).prefix(8) {
            let file = Self.evidenceDirectory.appendingPathComponent("\(e.id.uuidString).jpg")
            guard let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value else { continue }
            images.append(data)
            labels.append("\(clock.string(from: e.at)) \(e.bundle.split(separator: ".").last ?? ""): \(e.title)")
        }
        let observations = await Task.detached { Self.episodes(for: day) }.value
        let courses = CoachCourse.attribute(observations, context: Self.courseContext(for: [day]))
        let pack = CoachDay.Pack(day: day, commitment: days?.record(for: day)?.commitmentText, sessions: sessions,
                                 blocks: blocks, imageLabels: labels,
                                 observations: CoachDay.observationLines(observations, courses: courses),
                                 asOf: now < end ? now : nil)
        return (pack, images)
    }

    /// The semester's courses and the calendar's classes on those days.
    static func courseContext(for days: [Date]) -> CoachCourse.Context {
        let calendar = ClassCalendar.shared
        return CoachCourse.Context(coursePrefixes: calendar.coursePrefixes,
                                   classes: days.flatMap(calendar.classes(on:)).map {
                                       CoachCourse.ClassEvent(start: $0.start, end: $0.end, title: $0.title)
                                   })
    }

    /// Where the running subject was left, from the last three days of observations.
    nonisolated static func whereWasI(running: String) async -> WhereWasI.Line? {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0...2).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
        let context = await MainActor.run { courseContext(for: days) }
        return await Task.detached {
            let episodes = days.flatMap(episodes(for:))
            return WhereWasI.line(episodes, running: running, now: Date(),
                                  course: CoachCourse.resolver(episodes, context: context))
        }.value
    }

    /// The day's episode records (`Focus/episodes/DATE.jsonl`, written by the episode worker).
    nonisolated private static func episodes(for day: Date) -> [CoachEpisode.Record] {
        let file = journalDirectory.deletingLastPathComponent()
            .appendingPathComponent("episodes/\(CoachDay.dayKey(day)).jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(CoachEpisode.Record.self, from: Data($0.utf8)) }
            .filter { $0.source.privacy == .notBrowser || $0.source.privacy == .regular }
    }

    /// Privacy facts from the day's journal (metadata only; text isn't read).
    nonisolated private static func journalFacts(for day: Date) -> JournalFacts {
        var facts = JournalFacts()
        let key = CoachDay.dayKey(day)
        let files = (try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.lastPathComponent.hasPrefix(key) && file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let row = try? decoder.decode(ScreenJournal.Row.self, from: Data(line.utf8)) else { continue }
                if row.privacy == .notBrowser {
                    if let id = row.evidenceImageID { facts.eligibleImages.insert(id) }
                    continue
                }
                let k = row.bundle + "|" + row.title
                if row.cloudEligible {
                    facts.verified.insert(k)
                    if let id = row.evidenceImageID { facts.eligibleImages.insert(id) }
                } else {
                    facts.unverified.insert(k)
                }
            }
        }
        return facts
    }
}
