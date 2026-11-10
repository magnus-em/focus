import Foundation
import Combine
import FocusCore

/// Gathers the inputs for `Insights.summarize` (timer, window log, screen
/// readings and archive, observations, AI messages, applications, LeetCode)
/// off the main thread, recounts every minute while Insights is open, and
/// writes the analysis with a strong model on Sunday nights, after goal edits
/// and on request.
@MainActor
final class InsightsStore: ObservableObject {
    static let shared = InsightsStore()
    static let budgetKey = "insightsDailyCapUSD"

    @Published var days = 7 { didSet { refresh() } }
    @Published var endDay = Calendar.current.startOfDay(for: Date()) { didSet { refresh() } }
    @Published private(set) var summary: Insights.Summary?
    @Published private(set) var reports: [InsightsReport.Report] = []
    @Published private(set) var writing = false
    @Published private(set) var writeStatus = ""
    @Published private(set) var loading = false

    /// Set by the app: the timer's saved blocks and logged problems.
    var sessionsProvider: () -> [WorkSession] = { ScreenCoach.shared?.sessions ?? [] }
    var leetCodeProvider: () -> [Date] = { [] }

    private var timer: Timer?
    private var visible = 0
    private var goalSub: AnyCancellable?
    private var refreshID = 0

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/insights", isDirectory: true)
    }

    private init() {
        reports = Self.loadReports()
    }

    var period: DateInterval {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        let start = cal.date(byAdding: .day, value: -days, to: end) ?? end
        return DateInterval(start: start, end: min(end, max(start, Date())))
    }

    var latest: InsightsReport.Report? { reports.first }

    func start() {
        guard goalSub == nil else { return }
        goalSub = GoalsStore.shared.changed.debounce(for: .seconds(600), scheduler: DispatchQueue.main).sink { [weak self] in
            Task { await self?.write(reason: "goals changed") }
        }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.weeklyCheck() }
        }
        weeklyCheck()
    }

    func appeared() {
        visible += 1
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func disappeared() {
        visible = max(0, visible - 1)
        if visible == 0 { timer?.invalidate(); timer = nil }
    }

    /// Sunday from 8 PM, or any time a week has passed since the last report.
    private func weeklyCheck() {
        let now = Date()
        let cal = Calendar.current
        let last = reports.first { $0.author == "Focus" }?.writtenAt ?? .distantPast
        let sundayEvening = cal.component(.weekday, from: now) == 1 && cal.component(.hour, from: now) >= 20
        if (sundayEvening && now.timeIntervalSince(last) > 3 * 86400) || now.timeIntervalSince(last) > 7.5 * 86400 {
            Task { await write(reason: "weekly") }
        }
    }

    // MARK: - Counting

    func refresh() {
        refreshID += 1
        let id = refreshID
        loading = summary == nil
        Task {
            let input = await gather(period: period)
            let s = await Task.detached(priority: .utility) { Insights.summarize(input) }.value
            guard id == self.refreshID else { return }
            self.summary = s
            self.loading = false
        }
    }

    func gather(period: DateInterval) async -> Insights.Input {
        let settings = ScreenCoach.shared?.appSettings
        let lifeSet = Set(settings?.lifeTags ?? []).union(["Break", "Sleep", "Meals", "Leisure", "Admin", "Social"])
        let study: Set<String> = Set((settings?.tags ?? ["Math", "SWE", "AI", "HW", "LeetCode", "Quant"]).filter { !lifeSet.contains($0) && $0 != "Recruiting" })
        let sessions = sessionsProvider().compactMap { s -> Insights.Session? in
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            guard end > period.start, s.startTime < period.end else { return nil }
            let label = s.type == .work ? (s.label ?? "Focus") : "Break"
            return Insights.Session(start: s.startTime, end: end, category: label, isFocus: s.isFocus)
        } + runningSession(period: period)
        let live = ScreenWatcher.shared.spans(from: period.start, to: period.end)
        let goals = GoalsStore.shared.active
        let apps = RecruitingStore.shared.applications.map(\.at)
        let leet = leetCodeProvider()
        let away = PresenceMonitor.shared.spans(from: period.start, to: period.end).map { DateInterval(start: $0.start, end: $0.end) }
        let privateApps = ScreenWatcher.privateApps
        let ignored = Set(ScreenWatcher.userIgnored.keys)
        return await Task.detached(priority: .utility) {
            let archived = ScreenArchive.spans(from: period.start, to: period.end)
            let spans = (archived + live).filter { !ignored.contains($0.bundleID) }
            let labels = spans.map { WindowTimeline.Label(start: $0.start, end: $0.end, bundle: $0.bundleID, title: $0.title,
                                                          category: $0.summary == "Private" ? WindowTimeline.privateCategory : $0.category) }
            let appNames = Dictionary(spans.map { ($0.bundleID, $0.app) }, uniquingKeysWith: { a, _ in a })
            let events = WindowTimelineRecorder.events(from: period.start, to: period.end)
            let timelineSegs = WindowTimeline.segments(events, away: away, from: period.start, to: period.end)
                .filter { !ignored.contains($0.bundle) }
            let labeled = WindowTimeline.label(timelineSegs, with: labels, privateBundles: privateApps)
            // Where the window log has nothing (before it existed, or while it
            // was off), the screen readings stand in.
            let covered = timelineSegs.map { DateInterval(start: $0.start, end: $0.end) }
            let fallback = Insights.segments(fromReadings: labels.filter { l in
                !covered.contains { $0.start < l.end && $0.end > l.start }
            }, apps: appNames)
            let observations = Self.observations(from: period.start, to: period.end)
            let messages = AIChatStore.load(from: period.start, to: period.end)
            return Insights.Input(period: period, goals: goals, sessions: sessions, segments: labeled + fallback,
                                  observations: observations, aiMessages: messages, applications: apps,
                                  leetCodeSolves: leet, studyCategories: study, lifeCategories: lifeSet)
        }.value
    }

    private func runningSession(period: DateInterval) -> [Insights.Session] {
        guard let r = ScreenCoach.shared?.runningBlock, r.start < period.end else { return [] }
        let isLife = FocusCategories.isLife(r.label) || r.label == "Break"
        return [Insights.Session(start: max(r.start, period.start), end: min(Date(), period.end), category: r.label, isFocus: !isLife)]
    }

    nonisolated static func observations(from: Date, to: Date) -> [Insights.Observation] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/episodes", isDirectory: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var records: [CoachEpisode.Record] = []
        var day = Calendar.current.startOfDay(for: from)
        while day < to {
            let f = dir.appendingPathComponent("\(CoachDay.dayKey(day)).jsonl")
            if let text = try? String(contentsOf: f, encoding: .utf8) {
                records += text.split(separator: "\n").compactMap { try? dec.decode(CoachEpisode.Record.self, from: Data($0.utf8)) }
                    .filter { $0.source.privacy == .notBrowser || $0.source.privacy == .regular }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? to
        }
        let course = CoachCourse.resolver(records, context: CoachCourse.Context())
        return records.map { r in
            Insights.Observation(at: r.source.at, end: r.source.end, category: r.source.category, course: course(r),
                                 activity: r.understanding.activity, asked: r.understanding.askedByUser,
                                 concepts: r.understanding.concepts)
        }
    }

    // MARK: - Writing

    nonisolated static var reportsDirectory: URL { directory.appendingPathComponent("reports", isDirectory: true) }

    nonisolated static func loadReports() -> [InsightsReport.Report] {
        let fm = FileManager.default
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? fm.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(InsightsReport.Report.self, from: Data(contentsOf: $0)) }
            .sorted { $0.writtenAt > $1.writtenAt }
    }

    func reloadReports() { reports = Self.loadReports() }

    /// The facts for the last 7 days, as the model would read them, plus the
    /// schema; Claude Code writes a report from this when asked.
    func writeBundle() async -> URL? {
        let p = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: Date())!, end: Date())
        let (facts, _) = await facts(period: p)
        let bundle: [String: Any] = [
            "periodStart": ISO8601DateFormatter().string(from: p.start),
            "periodEnd": ISO8601DateFormatter().string(from: p.end),
            "system": InsightsReport.system, "facts": facts, "schema": InsightsReport.schema,
            "write": "Save a Report JSON (InsightsReport.Report, iso8601 dates, author \"Claude Code\") in Focus/insights/reports/",
        ]
        let url = Self.directory.appendingPathComponent("bundle.json")
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private func facts(period: DateInterval) async -> (String, Insights.Summary) {
        let input = await gather(period: period)
        let s = await Task.detached(priority: .utility) { Insights.summarize(input) }.value
        let doc = GoalsStore.shared.doc
        let notes = await Task.detached(priority: .utility) { Self.dayNotes(from: period.start, to: period.end) }.value
        let previous = reports.first { $0.writtenAt < period.end.addingTimeInterval(-3600) }
        return (InsightsReport.facts(s, goals: doc.goals, history: doc.history, days: notes, previous: previous), s)
    }

    nonisolated static func dayNotes(from: Date, to: Date) -> [InsightsReport.DayNote] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/days", isDirectory: true)
        var out: [InsightsReport.DayNote] = []
        var day = Calendar.current.startOfDay(for: from)
        while day < to {
            if let r = CoachDay.load(day, from: dir) {
                let c = r.content
                out.append(.init(date: day, headline: c.headline, courses: c.study.compactMap(\.course),
                                 shaky: c.study.flatMap(\.shaky)))
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? to
        }
        return out
    }

    func write(reason: String) async {
        guard !writing else { return }
        writing = true
        writeStatus = "Writing…"
        defer { writing = false }
        let p = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: Date())!, end: Date())
        let (facts, _) = await facts(period: p)
        do {
            let r = try await InsightsWriter.write(facts: facts, period: p)
            try Self.save(r)
            reports = Self.loadReports()
            writeStatus = "Written by \(r.model)\(r.costUSD.map { String(format: " for $%.2f", $0) } ?? "")"
            SyncLogBridge.note("insightsWritten", "\(reason) \(r.model)")
        } catch {
            writeStatus = "Couldn't write: \(error.localizedDescription)"
        }
    }

    nonisolated static func save(_ r: InsightsReport.Report) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        try enc.encode(r).write(to: reportsDirectory.appendingPathComponent("\(f.string(from: r.writtenAt))-\(r.author.replacingOccurrences(of: " ", with: "-")).json"), options: .atomic)
    }
}

/// Keeps the sync log line format in one place for Insights events.
enum SyncLogBridge {
    static func note(_ event: String, _ detail: String) {
        SyncLog.event(event, ["detail": detail])
    }
}
