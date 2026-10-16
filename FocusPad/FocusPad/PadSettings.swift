import Foundation
import SwiftUI
import FocusCore

final class PadSettings: ObservableObject {

    // Synced (UserDefaults + iCloud KVS via SyncedDefaults)
    @Published var workMinutes: Double {
        didSet { sd.set(workMinutes, forKey: "workMinutes") }
    }
    @Published var breakMinutes: Double {
        didSet { sd.set(breakMinutes, forKey: "shortBreakMinutes") }
    }
    @Published var dailyGoalHours: Int {
        didSet { sd.set(dailyGoalHours, forKey: "dailyGoalHours") }
    }
    @Published var autoStartBreaks: Bool {
        didSet { sd.set(autoStartBreaks, forKey: "autoStartBreaks") }
    }
    @Published var autoStartWork: Bool {
        didSet { sd.set(autoStartWork, forKey: "autoStartWork") }
    }
    @Published var pauseGraceMinutes: Int {
        didSet { sd.set(pauseGraceMinutes, forKey: "pauseGraceMinutes") }
    }
    @Published var soundEnabled: Bool {
        didSet { sd.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var tags: [String] {
        didSet { sd.set(tags, forKey: "tags") }
    }
    @Published var problemSources: [String] {
        didSet { sd.set(problemSources, forKey: "problemSources") }
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
    @Published var commitmentEnabled: Bool {
        didSet { sd.set(commitmentEnabled, forKey: "commitmentEnabled") }
    }
    @Published var todayCommitment: String {
        didSet { sd.set(todayCommitment, forKey: "todayCommitment") }
    }
    @Published var lastCommitmentDateEpoch: Double {
        didSet { sd.set(lastCommitmentDateEpoch, forKey: "lastCommitmentDateEpoch") }
    }
    @Published var interviewDate: Date? {
        didSet {
            sd.set(interviewDate?.timeIntervalSince1970 ?? 0, forKey: "interviewDate")
        }
    }

    // Device-local
    @Published var cloudKitSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(cloudKitSyncEnabled, forKey: "cloudKitSyncEnabled") }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    private let sd = SyncedDefaults.shared

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "workMinutes": 25.0,
            "shortBreakMinutes": 10.0,
            "dailyGoalHours": 4,
            "autoStartBreaks": true,
            "autoStartWork": false,
            "pauseGraceMinutes": 10,
            "soundEnabled": true,
            "tags": ["Quant", "SWE", "AI"],
            "problemSources": ["QuantGuide", "LeetCode"],
            "quantGoal": 0,
            "quantWeeklyGoal": 0,
            "sweGoal": 0,
            "sweWeeklyGoal": 0,
            "homeworkDailyGoal": 10,
            "commitmentEnabled": true,
            "cloudKitSyncEnabled": true,
        ])
        workMinutes = d.double(forKey: "workMinutes")
        breakMinutes = d.double(forKey: "shortBreakMinutes")
        dailyGoalHours = d.integer(forKey: "dailyGoalHours")
        autoStartBreaks = d.bool(forKey: "autoStartBreaks")
        autoStartWork = d.bool(forKey: "autoStartWork")
        pauseGraceMinutes = d.integer(forKey: "pauseGraceMinutes")
        soundEnabled = d.bool(forKey: "soundEnabled")
        tags = d.stringArray(forKey: "tags") ?? ["Quant", "SWE", "AI"]
        problemSources = d.stringArray(forKey: "problemSources") ?? ["QuantGuide", "LeetCode"]
        quantGoal = d.integer(forKey: "quantGoal")
        quantWeeklyGoal = d.integer(forKey: "quantWeeklyGoal")
        sweGoal = d.integer(forKey: "sweGoal")
        sweWeeklyGoal = d.integer(forKey: "sweWeeklyGoal")
        homeworkDailyGoal = d.integer(forKey: "homeworkDailyGoal")
        commitmentEnabled = d.bool(forKey: "commitmentEnabled")
        todayCommitment = d.string(forKey: "todayCommitment") ?? ""
        lastCommitmentDateEpoch = d.double(forKey: "lastCommitmentDateEpoch")
        let epoch = d.double(forKey: "interviewDate")
        interviewDate = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        cloudKitSyncEnabled = d.bool(forKey: "cloudKitSyncEnabled")
        hasCompletedOnboarding = d.bool(forKey: "hasCompletedOnboarding")

        if !d.bool(forKey: "didAddWellbeingGroup") {
            var lifeTags = d.stringArray(forKey: FocusCategories.lifeTagsKey) ?? FocusCategories.defaultLifeTags
            for tag in FocusCategories.wellbeingTags {
                if !tags.contains(tag) { tags.append(tag) }
                if !lifeTags.contains(tag) { lifeTags.append(tag) }
            }
            sd.set(tags, forKey: "tags")
            sd.set(lifeTags, forKey: FocusCategories.lifeTagsKey)
            d.set(true, forKey: "didAddWellbeingGroup")
        }

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
        breakMinutes = d.double(forKey: "shortBreakMinutes")
        dailyGoalHours = d.integer(forKey: "dailyGoalHours")
        autoStartBreaks = d.bool(forKey: "autoStartBreaks")
        autoStartWork = d.bool(forKey: "autoStartWork")
        pauseGraceMinutes = d.integer(forKey: "pauseGraceMinutes")
        soundEnabled = d.bool(forKey: "soundEnabled")
        tags = d.stringArray(forKey: "tags") ?? tags
        problemSources = d.stringArray(forKey: "problemSources") ?? problemSources
        quantGoal = d.integer(forKey: "quantGoal")
        quantWeeklyGoal = d.integer(forKey: "quantWeeklyGoal")
        sweGoal = d.integer(forKey: "sweGoal")
        sweWeeklyGoal = d.integer(forKey: "sweWeeklyGoal")
        homeworkDailyGoal = d.integer(forKey: "homeworkDailyGoal")
        commitmentEnabled = d.bool(forKey: "commitmentEnabled")
        todayCommitment = d.string(forKey: "todayCommitment") ?? todayCommitment
        lastCommitmentDateEpoch = d.double(forKey: "lastCommitmentDateEpoch")
        let epoch = d.double(forKey: "interviewDate")
        interviewDate = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    var needsCommitmentToday: Bool {
        guard commitmentEnabled else { return false }
        if lastCommitmentDateEpoch == 0 { return true }
        return !Calendar.current.isDateInToday(Date(timeIntervalSince1970: lastCommitmentDateEpoch))
    }

    func markCommitmentDone(_ text: String) {
        todayCommitment = text
        lastCommitmentDateEpoch = Date().timeIntervalSince1970
    }

    var engineSettings: FocusTimerEngine.Settings {
        .init(
            workMinutes: workMinutes,
            breakMinutes: breakMinutes,
            dailyGoalHours: dailyGoalHours,
            autoStartBreaks: autoStartBreaks,
            autoStartWork: autoStartWork,
            pauseGraceMinutes: pauseGraceMinutes
        )
    }
}
