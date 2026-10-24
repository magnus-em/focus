import Foundation
import Combine
import UserNotifications
import AppKit
import FocusCore

struct LCAttempt: Identifiable {
    let entry: ProblemEntry
    let problem: LCProblem
    let isFirstSolve: Bool
    var id: UUID { entry.id }
    var date: Date { entry.date }
}

enum LCStatus { case todo, solved(Confidence), reviewDue }

struct LCPatternStat: Identifiable {
    let category: String
    let solved: Int
    let attempts: Int
    /// 0 = struggled … 2 = got it; nil until attempted.
    let avgConfidence: Double?
    let lastPracticed: Date?
    let catalogCount: Int
    var id: String { category }
}

struct LCDay: Identifiable {
    let date: Date
    let easy: Int, medium: Int, hard: Int
    var total: Int { easy + medium + hard }
    var id: Date { date }
}

struct LCMilestone: Identifiable {
    let id: String
    let title: String
    let icon: String
    let current: Int
    let goal: Int
    var unlocked: Bool { current >= goal }
    var progress: Double { min(1, Double(current) / Double(max(goal, 1))) }
}

struct LCPick: Identifiable {
    let problem: LCProblem
    let reasons: [String]
    var id: String { problem.slug }
}

struct LeetCodeLogDetails {
    let title: String
    let difficulty: ProblemDifficulty
    let categories: [String]
    let solved: Bool
    let confidence: Confidence
    let minutes: Int?
    let usedHelp: Bool
    let notes: String
}

/// LeetCode grind tracking on top of `ProblemStore`: every solve is a normal SWE
/// `ProblemEntry` (so the review queue, dashboard and SWE goals keep working), matched
/// back to the catalog by URL slug. This store only derives stats and runs the stopwatch.
@MainActor
final class LeetCodeStore: ObservableObject {
    static let nudgeID = "leetcode-nudge"

    /// Interview-realistic solve targets, in minutes.
    static let targetMinutes: [ProblemDifficulty: Int] = [.easy: 15, .medium: 25, .hard: 40]
    /// Target share of solves per difficulty — mostly Mediums, like real interviews.
    static let targetMix: [ProblemDifficulty: Double] = [.easy: 0.2, .medium: 0.6, .hard: 0.2]
    /// Grind points per solve, so a Hard isn't worth the same as an Easy.
    static let points: [ProblemDifficulty: Int] = [.easy: 1, .medium: 2, .hard: 3]

    let catalog: LeetCodeCatalog
    private let problemStore: ProblemStore
    private let settings: AppSettings

    @Published private(set) var attempts: [LCAttempt] = []
    @Published private(set) var activeSlug: String?
    @Published private(set) var activeStart: Date?
    /// Transient banner text after a solve (goal hit, milestone unlocked).
    @Published var celebration: String?

    private(set) var solvedSlugs: Set<String> = []
    private(set) var latestBySlug: [String: LCAttempt] = [:]
    private var loggedProblems: [ProblemEntry] = []
    private var cancellables = Set<AnyCancellable>()
    private var solveDrafts: LeetCodeSolveDraftStore?
    var onStartPractice: (() -> Void)?
    @Published private(set) var practice = LeetCodePracticeState()
    @Published var finishingPractice: LeetCodePracticeState.Session?
    private weak var focusTimer: TimerManager?
    private var practiceTick: Timer?
    private var screenSlug: String?
    private var screenAt: Date?
    private var lastPracticeSave = Date.distantPast
    private static let practiceKey = "leetCode.practice.v1"

    init(catalog: LeetCodeCatalog, problemStore: ProblemStore, settings: AppSettings) {
        self.catalog = catalog
        self.problemStore = problemStore
        self.settings = settings

        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.practiceKey), let saved = try? JSONDecoder().decode(LeetCodePracticeState.self, from: data) {
            practice = saved
            practice.restore()
        } else if let slug = d.string(forKey: "leetCode.activeSlug") {
            practice.select(slug: slug, title: catalog.problem(slug: slug)?.title ?? slug.replacingOccurrences(of: "-", with: " "), at: Date())
        }
        activeSlug = practice.active?.slug
        activeStart = practice.active?.startedAt

        problemStore.$problems
            .sink { [weak self] in self?.recompute(from: $0) }
            .store(in: &cancellables)
        catalog.$problems
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.recompute(from: self.problemStore.problems)
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleNudge() }
            .store(in: &cancellables)
        // Menu-bar apps run for days: re-evaluate the nudge (and "today") after midnight.
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleNudge()
            }
            .store(in: &cancellables)
        solveDrafts = LeetCodeSolveDraftStore(store: self)
    }

    private func recompute(from problems: [ProblemEntry]) {
        loggedProblems = problems
        var seen = Set<String>()
        var list: [LCAttempt] = []
        for e in problems.sorted(by: { $0.date < $1.date }) {
            guard let p = catalog.problem(matching: e) else { continue }
            list.append(LCAttempt(entry: e, problem: p, isFirstSolve: !seen.contains(p.slug)))
            seen.insert(p.slug)
        }
        attempts = list
        solvedSlugs = seen
        latestBySlug = Dictionary(list.map { ($0.problem.slug, $0) }, uniquingKeysWith: { _, b in b })
        scheduleNudge()
    }

    // MARK: - Per-problem

    func status(of p: LCProblem) -> LCStatus {
        guard let latest = latestBySlug[p.slug] else { return .todo }
        return latest.entry.isDueForReview ? .reviewDue : .solved(latest.entry.confidence)
    }

    func history(of p: LCProblem) -> [LCAttempt] {
        attempts.filter { $0.problem.slug == p.slug }.reversed()
    }

    // MARK: - Stopwatch

    var activeProblem: LCProblem? { practice.active.map(problem(for:)) }
    var activePractice: LeetCodePracticeState.Session? { practice.active }
    var activeSeconds: Double { practice.active?.seconds ?? 0 }
    var practiceDrafts: [LeetCodePracticeState.Session] { practice.sessions.filter { $0.outcome == .draft }.reversed() }
    var recentPractice: [LeetCodePracticeState.Session] { Array(practice.sessions.reversed().prefix(20)) }
    var workingOnProblem: Bool {
        practice.active != nil && (practice.isTracking || (settings.screenWatch && screenSlug == practice.active?.slug && screenAt.map { Date().timeIntervalSince($0) >= 0 && Date().timeIntervalSince($0) < 90 } == true) || (focusTimer?.isActive == true && focusTimer?.currentLabel == FocusCategories.leetCode && focusTimer?.isOnBreak == false))
    }

    func problem(for session: LeetCodePracticeState.Session) -> LCProblem {
        let known = catalog.problem(slug: session.slug)
        return LCProblem(number: known?.number ?? 0, title: session.title, slug: session.slug,
            difficulty: session.difficulty ?? known?.difficulty ?? .medium, acceptance: known?.acceptance ?? 0,
            paidOnly: known?.paidOnly ?? false, tags: known?.tags ?? [],
            category: session.categories.first ?? known?.category ?? "", listMask: known?.listMask ?? 0)
    }

    func connectPractice(timer: TimerManager) {
        focusTimer = timer
        ScreenWatcher.shared.practiceObservations.sink { [weak self] observation in
            guard let self, abs(Date().timeIntervalSince(observation.at)) < 45 else { return }
            self.refreshPractice()
            self.screenSlug = observation.slug
            self.screenAt = observation.at
            self.practice.observePage(slug: observation.slug)
            if let slug = observation.slug {
                let title = self.catalog.problem(slug: slug)?.title ?? slug.replacingOccurrences(of: "-", with: " ").capitalized
                self.practice.select(slug: slug, title: title, at: Date(), automatic: true)
            }
            self.refreshPractice(forceSave: true)
        }.store(in: &cancellables)
        timer.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshPractice() }.store(in: &cancellables)
        practiceTick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPractice() }
        }
        if let practiceTick { RunLoop.main.add(practiceTick, forMode: .common) }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.refreshPractice(forceSave: true)
        }.store(in: &cancellables)
        refreshPractice()
    }

    private func shouldTrackPractice(at now: Date) -> Bool {
        guard practice.active != nil, !PresenceMonitor.shared.isAway else { return false }
        if let screenSlug, screenSlug != practice.active?.slug,
           screenAt.map({ now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 20 }) == true { return false }
        if let focusTimer, focusTimer.isActive {
            if !focusTimer.isRunning { return false }
            if !focusTimer.isOnBreak && focusTimer.currentLabel == FocusCategories.leetCode { return true }
            if focusTimer.isOnBreak { return false }
        }
        return settings.screenWatch && screenSlug == practice.active?.slug
            && screenAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 20 } == true
            && PresenceMonitor.idleSeconds < 90
    }

    private func refreshPractice(forceSave: Bool = false) {
        let now = Date()
        guard practice.active != nil || forceSave else { return }
        practice.update(at: now, tracking: shouldTrackPractice(at: now))
        activeSlug = practice.active?.slug
        activeStart = practice.active?.startedAt
        if forceSave || now.timeIntervalSince(lastPracticeSave) >= 15 { savePractice() }
    }

    private func savePractice() {
        practice.prune(at: Date())
        if let data = try? JSONEncoder().encode(practice) { UserDefaults.standard.set(data, forKey: Self.practiceKey) }
        lastPracticeSave = Date()
        if let activeSlug { UserDefaults.standard.set(activeSlug, forKey: "leetCode.activeSlug") }
        else { UserDefaults.standard.removeObject(forKey: "leetCode.activeSlug") }
        UserDefaults.standard.removeObject(forKey: "leetCode.activeStart")
    }

    func start(_ p: LCProblem) {
        refreshPractice()
        screenSlug = nil; screenAt = nil
        practice.select(slug: p.slug, title: p.title, at: Date())
        onStartPractice?()
        refreshPractice(forceSave: true)
    }

    func resumePractice(_ session: LeetCodePracticeState.Session) {
        screenSlug = nil; screenAt = nil
        practice.resume(id: session.id, at: Date())
        onStartPractice?()
        refreshPractice(forceSave: true)
    }

    func finishPractice() {
        guard finishingPractice == nil else { return }
        refreshPractice()
        finishingPractice = practice.finish(at: Date())
        if focusTimer?.currentLabel == FocusCategories.leetCode, focusTimer?.isActive == true { focusTimer?.stop(at: Date()) }
        refreshPractice(forceSave: true)
    }

    func reviewPractice(_ session: LeetCodePracticeState.Session) {
        guard finishingPractice == nil else { return }
        if session.id == practice.activeID { finishPractice(); return }
        finishingPractice = practice.prepareLog(id: session.id, at: Date())
        savePractice()
    }

    func cancelStopwatch() {
        finishPractice()
    }

    func elapsedMinutes(for p: LCProblem) -> Int? {
        guard practice.active?.slug == p.slug else { return nil }
        return practice.active?.minutes
    }

    func keepPracticeDetails(id: UUID, details: LeetCodePracticeState.Details) {
        practice.keepDetails(id: id, details: details)
        savePractice()
    }

    func completePractice(_ session: LeetCodePracticeState.Session, details: LeetCodeLogDetails) -> Bool {
        guard practice.sessions.contains(where: { $0.id == session.id && $0.outcome == .draft }) else { return false }
        if details.solved, !log(problem(for: session), confidence: details.confidence, minutes: details.minutes,
            usedHelp: details.usedHelp, notes: details.notes, at: session.finishedAt ?? session.startedAt,
            id: session.id, title: details.title, difficulty: details.difficulty, categories: details.categories) { return false }
        practice.complete(id: session.id, solved: details.solved, confidence: details.confidence,
                          usedHelp: details.usedHelp, notes: details.notes, title: details.title,
                          difficulty: details.difficulty, categories: details.categories, minutes: details.minutes)
        savePractice()
        finishingPractice = nil
        return true
    }

    func practiceDraft(slug: String) -> LeetCodePracticeState.Session? {
        practice.sessions.last { $0.slug == slug && $0.outcome == .draft }
    }

    func practiceLogged(slug: String, on date: Date) -> Bool {
        practice.sessions.contains { $0.slug == slug && $0.outcome != .draft && Calendar.current.isDate($0.finishedAt ?? $0.startedAt, inSameDayAs: date) }
    }

    /// An Accepted submission confirmed from the corner card closes the timed draft for that problem.
    /// The LeetCode timer keeps running: the next problem page starts its own draft.
    func confirmPracticeSolve(id: UUID, confidence: Confidence, usedHelp: Bool, minutes: Int?, notes: String) -> Bool {
        guard finishingPractice?.id != id else { return false }
        refreshPractice()
        guard let session = practice.prepareLog(id: id, at: Date()) else { return false }
        let p = problem(for: session)
        let details = LeetCodeLogDetails(title: session.title, difficulty: p.difficulty, categories: p.categories, solved: true,
                                         confidence: confidence, minutes: minutes ?? session.minutes, usedHelp: usedHelp, notes: notes)
        guard completePractice(session, details: details) else { savePractice(); return false }
        refreshPractice(forceSave: true)
        return true
    }

    // MARK: - Logging

    @discardableResult
    func log(_ p: LCProblem, confidence: Confidence, minutes: Int?, usedHelp: Bool, notes: String, at date: Date = Date(),
             id: UUID? = nil, title: String? = nil, difficulty: ProblemDifficulty? = nil, categories: [String]? = nil) -> Bool {
        if let id, loggedProblems.contains(where: { $0.id == id }) { return true }
        let milestonesBefore = Set(milestones.filter(\.unlocked).map(\.id))
        let source = settings.problemSources.first { $0.localizedCaseInsensitiveContains("leetcode") } ?? "LeetCode"
        guard problemStore.add(ProblemEntry(id: id ?? UUID(), date: date,
            title: title ?? p.title, domain: .swe, categories: categories ?? p.categories, difficulty: difficulty ?? p.difficulty,
            source: source, needsReview: usedHelp, confidence: confidence,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            url: p.url, solveMinutes: minutes
        )) else { return false }
        if let session = practice.finishForLog(slug: p.slug, sessionID: id, at: Date()) {
            practice.complete(id: session.id, solved: true, confidence: confidence, usedHelp: usedHelp, notes: notes, title: title ?? p.title)
            if focusTimer?.currentLabel == FocusCategories.leetCode, focusTimer?.isActive == true { focusTimer?.stop(at: Date()) }
            refreshPractice(forceSave: true)
        }

        let unlocked = milestones.filter { $0.unlocked && !milestonesBefore.contains($0.id) }
        if let m = unlocked.first {
            celebration = "Milestone unlocked — \(m.title)"
        } else if todayCount == dailyGoal {
            celebration = "Daily goal hit — \(todayCount) today. Streak: \(streak) day\(streak == 1 ? "" : "s")"
        } else if attempts.last?.isFirstSolve == true && p.difficulty == .hard {
            celebration = "Hard down. +\(Self.points[.hard]!) points"
        }
        return true
    }

    func delete(_ a: LCAttempt) { problemStore.delete(id: a.entry.id) }

    // MARK: - Today / streak

    var dailyGoal: Int { max(1, settings.leetCodeDailyGoal) }

    func setDailyGoal(_ n: Int) { settings.leetCodeDailyGoal = max(1, min(30, n)) }

    private func attempts(on day: Date) -> [LCAttempt] {
        let cal = Calendar.current
        return attempts.filter { cal.isDate($0.date, inSameDayAs: day) }
    }

    var today: [LCAttempt] { attempts(on: Date()) }
    private var todaySummary: LeetCodeDailyGoal.Summary { LeetCodeDailyGoal.summary(loggedProblems, on: Date()) }
    var todayCount: Int { todaySummary.total }
    var todayNew: Int { todaySummary.new }
    var todayRedo: Int { todaySummary.redo }
    var todayPoints: Int { today.reduce(0) { $0 + Self.points[$1.problem.difficulty]! } }

    private var activeDays: Set<Date> {
        let cal = Calendar.current
        return Set(attempts.map { cal.startOfDay(for: $0.date) })
    }

    /// Consecutive days with a solve. Today only counts once something's logged, so the
    /// streak isn't "broken" mid-morning.
    var streak: Int {
        let cal = Calendar.current
        let days = activeDays
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    var bestStreak: Int {
        let cal = Calendar.current
        let days = activeDays.sorted()
        var best = 0, run = 0
        var prev: Date?
        for d in days {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            best = max(best, run)
            prev = d
        }
        return best
    }

    var streakAtRisk: Bool { todayCount == 0 && streak > 0 }

    var bestDay: Int {
        let cal = Calendar.current
        return Dictionary(grouping: attempts) { cal.startOfDay(for: $0.date) }.values.map(\.count).max() ?? 0
    }

    func series(days: Int) -> [LCDay] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let grouped = Dictionary(grouping: attempts) { cal.startOfDay(for: $0.date) }
        return (0..<days).reversed().map { back in
            let day = cal.date(byAdding: .day, value: -back, to: todayStart)!
            let a = grouped[day] ?? []
            return LCDay(date: day,
                         easy: a.filter { $0.problem.difficulty == .easy }.count,
                         medium: a.filter { $0.problem.difficulty == .medium }.count,
                         hard: a.filter { $0.problem.difficulty == .hard }.count)
        }
    }

    func count(lastDays n: Int, endingDaysAgo offset: Int = 0) -> Int {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1 - offset, to: cal.startOfDay(for: Date()))!
        let start = cal.date(byAdding: .day, value: -n, to: end)!
        return attempts.filter { $0.date >= start && $0.date < end }.count
    }

    // MARK: - Totals

    var uniqueSolved: Int { solvedSlugs.count }

    func uniqueSolved(_ d: ProblemDifficulty) -> Int {
        latestBySlug.values.filter { $0.problem.difficulty == d }.count
    }

    func catalogCount(_ d: ProblemDifficulty) -> Int {
        catalog.problems.filter { $0.difficulty == d }.count
    }

    func progress(in list: LCList) -> (solved: Int, total: Int) {
        let members = catalog.problems.filter { $0.isIn(list) }
        return (members.filter { solvedSlugs.contains($0.slug) }.count, members.count)
    }

    // MARK: - Quality

    /// Share of recent solves done without hints/AI.
    var independentRate: Double? {
        let recent = attempts.suffix(30)
        guard !recent.isEmpty else { return nil }
        return Double(recent.filter { !$0.entry.needsReview }.count) / Double(recent.count)
    }

    func confidenceSplit(last n: Int = 30) -> [(Confidence, Int)] {
        let recent = attempts.suffix(n)
        return Confidence.allCases.map { c in (c, recent.filter { $0.entry.confidence == c }.count) }
    }

    func difficultyMix(lastDays n: Int = 30) -> [(ProblemDifficulty, Double)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: Date())!
        let recent = attempts.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return ProblemDifficulty.allCases.map { ($0, 0) } }
        return ProblemDifficulty.allCases.map { d in
            (d, Double(recent.filter { $0.problem.difficulty == d }.count) / Double(recent.count))
        }
    }

    func medianMinutes(_ d: ProblemDifficulty, last n: Int = 15) -> Int? {
        let times = attempts.filter { $0.problem.difficulty == d }.compactMap(\.entry.solveMinutes).suffix(n).sorted()
        guard !times.isEmpty else { return nil }
        return times[times.count / 2]
    }

    /// Median of the latest `n` timed solves vs the `n` before — negative means getting faster.
    func speedTrend(_ d: ProblemDifficulty, n: Int = 5) -> Int? {
        let times = attempts.filter { $0.problem.difficulty == d }.compactMap(\.entry.solveMinutes)
        guard times.count >= n * 2 else { return nil }
        func median(_ a: ArraySlice<Int>) -> Int { let s = a.sorted(); return s[s.count / 2] }
        return median(times.suffix(n)) - median(times.dropLast(n).suffix(n))
    }

    // MARK: - Patterns

    var patternStats: [LCPatternStat] {
        let byCat = Dictionary(grouping: attempts, by: \.problem.category)
        let catalogByCat = Dictionary(grouping: catalog.problems, by: \.category).mapValues(\.count)
        return ProblemDomain.swe.categories.map { cat in
            let a = byCat[cat] ?? []
            let scores = a.map { Self.score($0.entry.confidence) }
            return LCPatternStat(
                category: cat,
                solved: Set(a.map(\.problem.slug)).count,
                attempts: a.count,
                avgConfidence: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                lastPracticed: a.last?.date,
                catalogCount: catalogByCat[cat] ?? 0
            )
        }
    }

    private static func score(_ c: Confidence) -> Double {
        switch c { case .solid: return 2; case .shaky: return 1; case .struggled: return 0 }
    }

    /// Higher = needs more work. Mixes thin coverage, low confidence and staleness.
    private func need(_ s: LCPatternStat) -> Double {
        let coverage = 1 / Double(1 + s.solved)
        let confidence = s.avgConfidence.map { (2 - $0) / 2 } ?? 1
        let days = s.lastPracticed.map { Date().timeIntervalSince($0) / 86400 } ?? 14
        return coverage * 1.5 + confidence + min(days, 14) / 14 * 0.6
    }

    var weakestPatterns: [LCPatternStat] {
        patternStats.sorted { need($0) > need($1) }
    }

    // MARK: - Review queue

    /// Problems whose most recent attempt is due again (shaky/struggled/used help).
    var reviewQueue: [LCAttempt] {
        latestBySlug.values
            .filter { $0.entry.isDueForReview }
            .sorted { ($0.entry.reviewDueDate ?? .distantPast) < ($1.entry.reviewDueDate ?? .distantPast) }
    }

    // MARK: - Pace

    var deadline: Date? { settings.leetCodeDeadline ?? settings.interviewDate }

    var daysLeft: Int? {
        guard let d = deadline else { return nil }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0)
    }

    /// New unique problems per day over the last 7 days.
    var recentPace: Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return Double(attempts.filter { $0.isFirstSolve && $0.date >= cutoff }.count) / 7
    }

    var neededPerDay: Double? {
        guard let left = daysLeft else { return nil }
        let remaining = max(0, settings.leetCodeTarget - uniqueSolved)
        return left == 0 ? Double(remaining) : Double(remaining) / Double(left)
    }

    var projectedTotal: Int? {
        guard let left = daysLeft else { return nil }
        return uniqueSolved + Int((recentPace * Double(left)).rounded())
    }

    // MARK: - Milestones

    var milestones: [LCMilestone] {
        let hard = uniqueSolved(.hard)
        let touched = patternStats.filter { $0.solved > 0 }.count
        let best = bestStreak
        let fastMedium = attempts.contains { $0.problem.difficulty == .medium && ($0.entry.solveMinutes ?? .max) <= 20 } ? 1 : 0
        var list: [LCMilestone] = [1, 10, 25, 50, 100, 150, 200, 300, 500].map {
            LCMilestone(id: "solved-\($0)", title: $0 == 1 ? "First solve" : "\($0) solved",
                        icon: "checkmark.seal.fill", current: uniqueSolved, goal: $0)
        }
        list += [1, 10, 25].map {
            LCMilestone(id: "hard-\($0)", title: $0 == 1 ? "First Hard" : "\($0) Hards",
                        icon: "flame.fill", current: hard, goal: $0)
        }
        list += [3, 7, 14, 30].map {
            LCMilestone(id: "streak-\($0)", title: "\($0)-day streak", icon: "bolt.fill", current: best, goal: $0)
        }
        list += [5, 10].map {
            LCMilestone(id: "day-\($0)", title: "\($0) in one day", icon: "sun.max.fill", current: bestDay, goal: $0)
        }
        list.append(LCMilestone(id: "patterns", title: "Every pattern touched", icon: "square.grid.3x3.fill",
                                current: touched, goal: ProblemDomain.swe.categories.count))
        list.append(LCMilestone(id: "fast-medium", title: "Medium in ≤ 20 min", icon: "stopwatch.fill",
                                current: fastMedium, goal: 1))
        for l in [LCList.blind75, .grind75, .neetcode150] {
            let p = progress(in: l)
            list.append(LCMilestone(id: "list-\(l.rawValue)", title: "\(l.title) complete", icon: "star.fill",
                                    current: p.solved, goal: max(p.total, 1)))
        }
        return list
    }

    // MARK: - Picking what to do next

    func randomPick(from pool: [LCProblem], includePremium: Bool) -> LCPick? {
        let candidates = pool.filter { !solvedSlugs.contains($0.slug) && (includePremium || !$0.paidOnly) }
        return candidates.randomElement().map { LCPick(problem: $0, reasons: ["Random unsolved problem"]) }
    }

    /// Targets the weakest pattern and whichever difficulty is most under its target share,
    /// preferring curated interview lists and reasonable acceptance rates.
    func smartPick(includePremium: Bool) -> LCPick? {
        let pool = catalog.problems.filter { !solvedSlugs.contains($0.slug) && (includePremium || !$0.paidOnly) }
        guard !pool.isEmpty else { return nil }

        let weak = Array(weakestPatterns.prefix(3))
        let pattern = weighted(weak.enumerated().map { ($0.element, 3.0 - Double($0.offset)) }) ?? weak.first

        let mix = Dictionary(uniqueKeysWithValues: difficultyMix())
        let hasHistory = attempts.count >= 5
        let difficulty: ProblemDifficulty = hasHistory
            ? ProblemDifficulty.allCases.max { (Self.targetMix[$0]! - mix[$0]!) < (Self.targetMix[$1]! - mix[$1]!) }!
            : (uniqueSolved < 3 ? .easy : .medium)

        var candidates = pool.filter { $0.category == pattern?.category && $0.difficulty == difficulty }
        if candidates.isEmpty { candidates = pool.filter { $0.category == pattern?.category } }
        if candidates.isEmpty { candidates = pool }

        let choice = weighted(candidates.map { p in
            var w = 1.0
            if p.isIn(.neetcode150) || p.isIn(.grind169) || p.isIn(.blind75) { w *= 6 }
            else if p.isCurated { w *= 3 }
            if (35...75).contains(p.acceptance) { w *= 1.5 }
            return (p, w)
        }) ?? candidates[0]

        var reasons: [String] = []
        if let s = pattern {
            if s.solved == 0 {
                reasons.append("You haven't touched \(s.category) yet")
            } else if let c = s.avgConfidence, c < 1.3 {
                reasons.append("\(s.category) is shaky (\(s.solved) solved, low confidence)")
            } else {
                reasons.append("\(s.category) is one of your thinnest patterns (\(s.solved) solved)")
            }
        }
        if hasHistory, choice.difficulty == difficulty {
            let pct = Int((mix[difficulty]! * 100).rounded())
            let target = Int(Self.targetMix[difficulty]! * 100)
            reasons.append("\(difficulty.rawValue)s are \(pct)% of your last 30 days (target \(target)%)")
        }
        let lists = LCList.allCases.filter { choice.isIn($0) }.map(\.title)
        if !lists.isEmpty { reasons.append("On \(lists.joined(separator: ", "))") }
        return LCPick(problem: choice, reasons: reasons)
    }

    private func weighted<T>(_ items: [(T, Double)]) -> T? {
        let total = items.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return items.first?.0 }
        var r = Double.random(in: 0..<total)
        for (item, w) in items {
            r -= w
            if r < 0 { return item }
        }
        return items.last?.0
    }

    // MARK: - Evening nudge

    private func scheduleNudge() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.nudgeID])
        guard settings.leetCodeNudge, !attempts.isEmpty, todayCount < dailyGoal else { return }

        let cal = Calendar.current
        guard let fire = cal.date(bySettingHour: settings.leetCodeNudgeMinutes / 60,
                                  minute: settings.leetCodeNudgeMinutes % 60, second: 0, of: Date()),
              fire > Date() else { return }

        let remaining = dailyGoal - todayCount
        let content = UNMutableNotificationContent()
        if todayCount == 0 && streak > 0 {
            content.title = "Your \(streak)-day LeetCode streak ends at midnight"
            content.body = "One problem keeps it alive. \(dailyGoal) hits today's goal."
        } else {
            content.title = "\(remaining) more LeetCode to hit today's goal"
            content.body = todayCount == 0
                ? "Nothing logged yet today — start with one Medium."
                : "\(todayCount)/\(dailyGoal) done. Finish the set."
        }
        content.sound = .default
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: Self.nudgeID, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}
