import Foundation
import FocusCore

class AppSettings: ObservableObject {
    // MARK: - Synced settings (UserDefaults + iCloud KVS)

    @Published var workMinutes: Double {
        didSet { sd.set(workMinutes, forKey: "workMinutes") }
    }
    @Published var shortBreakMinutes: Double {
        didSet { sd.set(shortBreakMinutes, forKey: "shortBreakMinutes") }
    }
    @Published var longBreakMinutes: Double {
        didSet { sd.set(longBreakMinutes, forKey: "longBreakMinutes") }
    }
    @Published var sessionsBeforeLongBreak: Int {
        didSet { sd.set(sessionsBeforeLongBreak, forKey: "sessionsBeforeLongBreak") }
    }
    @Published var dailyGoal: Int {
        didSet { sd.set(dailyGoal, forKey: "dailyGoalHours") }
    }
    @Published var autoStartBreaks: Bool {
        didSet { sd.set(autoStartBreaks, forKey: "autoStartBreaks") }
    }
    @Published var autoStartWork: Bool {
        didSet { sd.set(autoStartWork, forKey: "autoStartWork") }
    }
    @Published var soundEnabled: Bool {
        didSet { sd.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var tags: [String] {
        didSet { sd.set(tags, forKey: "tags") }
    }
    /// Subset of `tags` that are life categories (tracked, not counted toward the goal).
    @Published var lifeTags: [String] {
        didSet { sd.set(lifeTags, forKey: FocusCategories.lifeTagsKey) }
    }
    /// Category the ⌃⌥⌘K quick-start hotkey tags a session with.
    @Published var quickStartTag: String {
        didSet { sd.set(quickStartTag, forKey: "quickStartTag") }
    }
    @Published var pauseGraceMinutes: Int {
        didSet { sd.set(pauseGraceMinutes, forKey: "pauseGraceMinutes") }
    }
    @Published var autoBreakEnabled: Bool {
        didSet { sd.set(autoBreakEnabled, forKey: "autoBreakEnabled") }
    }
    @Published var commitmentEnabled: Bool {
        didSet { sd.set(commitmentEnabled, forKey: "commitmentEnabled") }
    }
    @Published var lastCommitmentDateEpoch: Double {
        didSet { sd.set(lastCommitmentDateEpoch, forKey: "lastCommitmentDateEpoch") }
    }
    @Published var todayCommitment: String {
        didSet { sd.set(todayCommitment, forKey: "todayCommitment") }
    }
    /// Unique LeetCode problems to reach by `leetCodeDeadline`.
    @Published var leetCodeTarget: Int {
        didSet { sd.set(leetCodeTarget, forKey: "leetCodeTarget") }
    }
    @Published var leetCodeDeadline: Date? {
        didSet { sd.set(leetCodeDeadline?.timeIntervalSince1970 ?? 0, forKey: "leetCodeDeadline") }
    }
    @Published var leetCodeNudge: Bool {
        didSet { sd.set(leetCodeNudge, forKey: "leetCodeNudge") }
    }
    @Published var leetCodeNudgeMinutes: Int {
        didSet { sd.set(leetCodeNudgeMinutes, forKey: "leetCodeNudgeMinutes") }
    }
    @Published var commitmentReviewReminder: Bool {
        didSet { sd.set(commitmentReviewReminder, forKey: "commitmentReviewReminder") }
    }
    /// Minutes after midnight for the end-of-day "did you do it?" notification.
    @Published var commitmentReviewMinutes: Int {
        didSet { sd.set(commitmentReviewMinutes, forKey: "commitmentReviewMinutes") }
    }
    @Published var quantGoal: Int {
        didSet { sd.set(quantGoal, forKey: "quantGoal") }
    }
    @Published var quantWeeklyGoal: Int {
        didSet { sd.set(quantWeeklyGoal, forKey: "quantWeeklyGoal") }
    }
    @Published var sweGoal: Int {
        didSet { sd.set(sweGoal, forKey: "sweGoal") }
    }
    @Published var sweWeeklyGoal: Int {
        didSet { sd.set(sweWeeklyGoal, forKey: "sweWeeklyGoal") }
    }
    @Published var homeworkDailyGoal: Int {
        didSet { sd.set(homeworkDailyGoal, forKey: "homeworkDailyGoal") }
    }
    @Published var problemSources: [String] {
        didSet { sd.set(problemSources, forKey: "problemSources") }
    }
    /// Ask for a from-memory recall when a focus block of `recallMinMinutes`+ ends.
    @Published var recallAfterSession: Bool {
        didSet { sd.set(recallAfterSession, forKey: "recallAfterSession") }
    }
    @Published var recallMinMinutes: Int {
        didSet { sd.set(recallMinMinutes, forKey: "recallMinMinutes") }
    }
    /// Reconstruct yesterday before the timeline is shown, when opening the day.
    @Published var morningRecall: Bool {
        didSet { sd.set(morningRecall, forKey: "morningRecall") }
    }
    @Published var recallDailyCap: Int {
        didSet { sd.set(recallDailyCap, forKey: "recallDailyCap") }
    }
    /// Shortcut that receives the morning review and files it in Journal. Empty = don't send.
    @Published var journalShortcut: String {
        didSet { sd.set(journalShortcut, forKey: "journalShortcut") }
    }
    /// Capture + read the frontmost window every 30s (`ScreenWatcher`).
    @Published var screenWatch: Bool {
        didSet { sd.set(screenWatch, forKey: "screenWatch") }
    }
    /// Offer a backdated switch when the screen shows another category.
    @Published var screenSuggest: Bool {
        didSet { sd.set(screenSuggest, forKey: "screenSuggest") }
    }
    @Published var screenAutoSwitch: Bool {
        didSet { sd.set(screenAutoSwitch, forKey: "screenAutoSwitch") }
    }
    /// Testing: a card ~30s after every category change the screen sees.
    @Published var screenEverySwitch: Bool {
        didSet { sd.set(screenEverySwitch, forKey: "screenEverySwitch") }
    }
    @Published var screenSuggestMinutes: Int {
        didSet { sd.set(screenSuggestMinutes, forKey: "screenSuggestMinutes") }
    }
    /// On return from `awayPromptMinutes`+ away from the Mac, ask what it was.
    @Published var awayPrompts: Bool {
        didSet { sd.set(awayPrompts, forKey: "awayPrompts") }
    }
    @Published var awayPromptMinutes: Int {
        didSet { sd.set(awayPromptMinutes, forKey: "awayPromptMinutes") }
    }
    /// Nudge when the day is open, you're at the Mac and nothing is running.
    @Published var idleNudge: Bool {
        didSet { sd.set(idleNudge, forKey: "idleNudge") }
    }
    @Published var interviewDate: Date? {
        didSet {
            sd.set(interviewDate?.timeIntervalSince1970 ?? 0, forKey: "interviewDate")
        }
    }

    // MARK: - Device-local (Mac-specific)

    @Published var siteBlockingEnabled: Bool {
        didSet { UserDefaults.standard.set(siteBlockingEnabled, forKey: "siteBlockingEnabled") }
    }
    @Published var blockDuringBreaks: Bool {
        didSet { UserDefaults.standard.set(blockDuringBreaks, forKey: "blockDuringBreaks") }
    }
    @Published var blockedSites: [String] {
        didSet { UserDefaults.standard.set(blockedSites, forKey: "blockedSites") }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    private let sd = SyncedDefaults.shared

    var needsCommitmentToday: Bool {
        guard commitmentEnabled else { return false }
        if lastCommitmentDateEpoch == 0 { return true }
        return !Calendar.current.isDateInToday(Date(timeIntervalSince1970: lastCommitmentDateEpoch))
    }

    func markCommitmentDone(text: String) {
        todayCommitment = text
        lastCommitmentDateEpoch = Date().timeIntervalSince1970
    }

    init() {
        let d = UserDefaults.standard

        if !d.bool(forKey: "hasCompletedOnboarding") {
            let priorState = (d.stringArray(forKey: "tags")?.isEmpty == false)
                || d.double(forKey: "lastCommitmentDateEpoch") > 0
                || (d.string(forKey: "todayCommitment")?.isEmpty == false)
                || d.double(forKey: "workMinutes") > 0
            if priorState { d.set(true, forKey: "hasCompletedOnboarding") }
        }

        d.register(defaults: [
            "workMinutes": 25.0,
            "shortBreakMinutes": 10.0,
            "longBreakMinutes": 15.0,
            "sessionsBeforeLongBreak": 4,
            "dailyGoalHours": 4,
            "autoStartBreaks": true,
            "autoStartWork": false,
            "soundEnabled": true,
            "siteBlockingEnabled": false,
            "blockDuringBreaks": false,
            "pauseGraceMinutes": 10,
            "autoBreakEnabled": true,
            "commitmentEnabled": true,
            "commitmentReviewReminder": true,
            "leetCodeTarget": 150,
            "leetCodeNudge": true,
            "leetCodeNudgeMinutes": 20 * 60,
            "commitmentReviewMinutes": 21 * 60,
            "quantGoal": 0,
            "quantWeeklyGoal": 0,
            "sweGoal": 0,
            "sweWeeklyGoal": 0,
            "homeworkDailyGoal": 10,
            "problemSources": ["QuantGuide", "LeetCode"],
            "recallAfterSession": true,
            "recallMinMinutes": 20,
            "morningRecall": true,
            "recallDailyCap": 12,
            "journalShortcut": "",
            "awayPrompts": true,
            "screenWatch": true,
            "screenSuggest": true,
            "screenSuggestMinutes": 2,
            "screenAutoSwitch": true,
            "screenEverySwitch": false,
            "awayPromptMinutes": 15,
            "idleNudge": true,
        ])
        workMinutes = d.double(forKey: "workMinutes")
        shortBreakMinutes = d.double(forKey: "shortBreakMinutes")
        longBreakMinutes = d.double(forKey: "longBreakMinutes")
        sessionsBeforeLongBreak = d.integer(forKey: "sessionsBeforeLongBreak")
        dailyGoal = d.integer(forKey: "dailyGoalHours")
        autoStartBreaks = d.bool(forKey: "autoStartBreaks")
        autoStartWork = d.bool(forKey: "autoStartWork")
        soundEnabled = d.bool(forKey: "soundEnabled")
        siteBlockingEnabled = d.bool(forKey: "siteBlockingEnabled")
        blockDuringBreaks = d.bool(forKey: "blockDuringBreaks")
        blockedSites = d.stringArray(forKey: "blockedSites") ?? []
        tags = d.stringArray(forKey: "tags") ?? []
        lifeTags = d.stringArray(forKey: FocusCategories.lifeTagsKey) ?? []
        quickStartTag = d.string(forKey: "quickStartTag") ?? "HW"
        pauseGraceMinutes = d.integer(forKey: "pauseGraceMinutes")
        autoBreakEnabled = d.bool(forKey: "autoBreakEnabled")
        commitmentEnabled = d.bool(forKey: "commitmentEnabled")
        lastCommitmentDateEpoch = d.double(forKey: "lastCommitmentDateEpoch")
        todayCommitment = d.string(forKey: "todayCommitment") ?? ""
        commitmentReviewReminder = d.bool(forKey: "commitmentReviewReminder")
        commitmentReviewMinutes = d.integer(forKey: "commitmentReviewMinutes")
        leetCodeTarget = d.integer(forKey: "leetCodeTarget")
        let lcDeadline = d.double(forKey: "leetCodeDeadline")
        leetCodeDeadline = lcDeadline > 0 ? Date(timeIntervalSince1970: lcDeadline) : nil
        leetCodeNudge = d.bool(forKey: "leetCodeNudge")
        leetCodeNudgeMinutes = d.integer(forKey: "leetCodeNudgeMinutes")
        quantGoal = d.integer(forKey: "quantGoal")
        quantWeeklyGoal = d.integer(forKey: "quantWeeklyGoal")
        sweGoal = d.integer(forKey: "sweGoal")
        sweWeeklyGoal = d.integer(forKey: "sweWeeklyGoal")
        homeworkDailyGoal = d.integer(forKey: "homeworkDailyGoal")
        problemSources = d.stringArray(forKey: "problemSources") ?? ["QuantGuide", "LeetCode"]
        recallAfterSession = d.bool(forKey: "recallAfterSession")
        recallMinMinutes = d.integer(forKey: "recallMinMinutes")
        morningRecall = d.bool(forKey: "morningRecall")
        recallDailyCap = d.integer(forKey: "recallDailyCap")
        journalShortcut = d.string(forKey: "journalShortcut") ?? ""
        awayPrompts = d.bool(forKey: "awayPrompts")
        screenWatch = d.bool(forKey: "screenWatch")
        screenSuggest = d.bool(forKey: "screenSuggest")
        screenSuggestMinutes = d.integer(forKey: "screenSuggestMinutes")
        screenAutoSwitch = d.bool(forKey: "screenAutoSwitch")
        screenEverySwitch = d.bool(forKey: "screenEverySwitch")
        awayPromptMinutes = d.integer(forKey: "awayPromptMinutes")
        idleNudge = d.bool(forKey: "idleNudge")
        let epoch = d.double(forKey: "interviewDate")
        interviewDate = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")

        if !d.bool(forKey: "didAddHWChoresTags") {
            for t in ["HW", "Chores"] where !tags.contains(t) { tags.append(t) }
            sd.set(tags, forKey: "tags")
            d.set(true, forKey: "didAddHWChoresTags")
        }

        if !d.bool(forKey: "didAddLifeCategories") {
            let order = ["Quant", "SWE", "AI", "HW", "Class", "Meals", "Leisure", "Sleep", "Chores",
                         "Exercise", "Social", "Commute", "Admin"]
            tags = order.filter { tags.contains($0) || !["Quant", "SWE", "AI", "HW"].contains($0) }
                + tags.filter { !order.contains($0) }
            lifeTags = FocusCategories.defaultLifeTags
            d.set(true, forKey: "didAddLifeCategories")
        }
        if !d.bool(forKey: "didAddJournalingCategory") {
            if !tags.contains("Journaling") { tags.append("Journaling") }
            if !lifeTags.contains("Journaling") { lifeTags.append("Journaling") }
            d.set(true, forKey: "didAddJournalingCategory")
        }
        // didSet doesn't fire in init, so the migrations above only wrote locally.
        sd.set(tags, forKey: "tags")
        sd.set(lifeTags, forKey: FocusCategories.lifeTagsKey)

        if tags.contains("AI/ML") {
            tags = tags.map { $0 == "AI/ML" ? "AI" : $0 }
            sd.set(tags, forKey: "tags")
        }

        // When another device updates synced settings, refresh from defaults.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadFromDefaults),
            name: SyncedDefaults.didImportRemoteChanges,
            object: nil
        )
    }

    @objc private func reloadFromDefaults() {
        sd.isReloading = true
        defer { sd.isReloading = false }
        let d = UserDefaults.standard
        workMinutes = d.double(forKey: "workMinutes")
        shortBreakMinutes = d.double(forKey: "shortBreakMinutes")
        longBreakMinutes = d.double(forKey: "longBreakMinutes")
        sessionsBeforeLongBreak = d.integer(forKey: "sessionsBeforeLongBreak")
        dailyGoal = d.integer(forKey: "dailyGoalHours")
        autoStartBreaks = d.bool(forKey: "autoStartBreaks")
        autoStartWork = d.bool(forKey: "autoStartWork")
        soundEnabled = d.bool(forKey: "soundEnabled")
        tags = d.stringArray(forKey: "tags") ?? tags
        lifeTags = d.stringArray(forKey: FocusCategories.lifeTagsKey) ?? lifeTags
        pauseGraceMinutes = d.integer(forKey: "pauseGraceMinutes")
        autoBreakEnabled = d.bool(forKey: "autoBreakEnabled")
        commitmentEnabled = d.bool(forKey: "commitmentEnabled")
        lastCommitmentDateEpoch = d.double(forKey: "lastCommitmentDateEpoch")
        todayCommitment = d.string(forKey: "todayCommitment") ?? todayCommitment
        commitmentReviewReminder = d.bool(forKey: "commitmentReviewReminder")
        commitmentReviewMinutes = d.integer(forKey: "commitmentReviewMinutes")
        leetCodeTarget = d.integer(forKey: "leetCodeTarget")
        let lcDeadline = d.double(forKey: "leetCodeDeadline")
        leetCodeDeadline = lcDeadline > 0 ? Date(timeIntervalSince1970: lcDeadline) : nil
        leetCodeNudge = d.bool(forKey: "leetCodeNudge")
        leetCodeNudgeMinutes = d.integer(forKey: "leetCodeNudgeMinutes")
        quantGoal = d.integer(forKey: "quantGoal")
        quantWeeklyGoal = d.integer(forKey: "quantWeeklyGoal")
        sweGoal = d.integer(forKey: "sweGoal")
        sweWeeklyGoal = d.integer(forKey: "sweWeeklyGoal")
        homeworkDailyGoal = d.integer(forKey: "homeworkDailyGoal")
        problemSources = d.stringArray(forKey: "problemSources") ?? problemSources
        recallAfterSession = d.bool(forKey: "recallAfterSession")
        recallMinMinutes = d.integer(forKey: "recallMinMinutes")
        morningRecall = d.bool(forKey: "morningRecall")
        recallDailyCap = d.integer(forKey: "recallDailyCap")
        journalShortcut = d.string(forKey: "journalShortcut") ?? ""
        awayPrompts = d.bool(forKey: "awayPrompts")
        screenWatch = d.bool(forKey: "screenWatch")
        screenSuggest = d.bool(forKey: "screenSuggest")
        screenSuggestMinutes = d.integer(forKey: "screenSuggestMinutes")
        screenAutoSwitch = d.bool(forKey: "screenAutoSwitch")
        screenEverySwitch = d.bool(forKey: "screenEverySwitch")
        awayPromptMinutes = d.integer(forKey: "awayPromptMinutes")
        idleNudge = d.bool(forKey: "idleNudge")
        let epoch = d.double(forKey: "interviewDate")
        interviewDate = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
}
