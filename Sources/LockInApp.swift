import SwiftUI
import SwiftData
import FocusCore


/// Shared SwiftData container. CloudKit sync is on by default — the build
/// is properly entitled for `iCloud.com.magnus.focustracker` and we want
/// Mac ↔ iPad sync. The previous one-off async crash during
/// `NSCloudKitMirroringDelegate._performSetupRequest` was triggered by a
/// mass-delete from the practice-history Reset button burning through
/// CloudKit's setup queue all at once — a one-shot, not a structural
/// problem. We re-enable sync by default and also force-clear any
/// stale `cloudKitSyncEnabled = false` that the previous safety override
/// may have written to UserDefaults, so the iPad starts catching up on
/// the next launch.
private let focusContainer: ModelContainer = {
    // One-time recovery: previous builds force-disabled sync after the
    // crash. Force-clear that flag so this launch re-enables iCloud.
    // (Idempotent — removing a missing key is a no-op.)
    UserDefaults.standard.removeObject(forKey: "cloudKitSyncEnabled")

    let useCloud = UserDefaults.standard.object(forKey: "cloudKitSyncEnabled") as? Bool ?? true
    do {
        return try FocusModelContainer.make(cloudKitSync: useCloud)
    } catch {
        // Cloud setup can fail (no entitlement on a stripped build, no
        // iCloud login, network down at launch). Fall back to local-only
        // so the app still opens; sync resumes the next time it succeeds.
        print("[FocusContainer] CloudKit container init failed, falling back to local-only: \(error)")
        return try! FocusModelContainer.make(cloudKitSync: false)
    }
}()

private func runOneShotMigration() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let appDir = appSupport.appendingPathComponent("Focus")
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    let result = FocusMigration.migrateIfNeeded(container: focusContainer, appSupportDir: appDir)
    if !result.alreadyMigrated {
        print("[FocusMigration] sessions=\(result.sessions) problems=\(result.problems) homework=\(result.homework) days=\(result.dayRecords) scratch=\(result.scratch)")
    }
    // Strict dedup at startup — safe because the key includes whole-second
    // start, type, label, AND duration rounded to 0.01 min. Two genuinely
    // distinct sessions (even back-to-back 60-min Quant blocks) won't match
    // because their startTime seconds differ. Only byte-identical CloudKit
    // double-imports collapse.
    let removed = FocusMigration.dedupeWorkSessions(container: focusContainer)
    if removed > 0 { print("[FocusMigration] startup dedup removed \(removed) duplicate session(s)") }

    // Recover any local rows that lack CloudKit metadata — these are
    // invisible to NSPersistentCloudKit and won't sync. Re-inserts them
    // through the SwiftData API so the export pipeline picks them up.
    let recovered = FocusMigration.recoverOrphanSessions(container: focusContainer)
    if recovered > 0 { print("[FocusMigration] startup recovered \(recovered) orphan session(s) for CK sync") }
}

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(FocusAppDelegate.self) private var appDelegate
    @StateObject private var timerManager: TimerManager
    @StateObject private var sessionStore: SessionStore
    @StateObject private var settings: AppSettings
    @StateObject private var problemStore: ProblemStore
    @StateObject private var homeworkStore: HomeworkStore
    @StateObject private var scratchStore: ScratchStore
    @StateObject private var healthStore: HealthStore
    @StateObject private var browserStore: BrowserStore
    @StateObject private var dayStore: DayStore
    @StateObject private var dashboardController: DashboardWindowController
    @StateObject private var onboardingController: OnboardingWindowController
    @StateObject private var practiceStore: PracticeStore
    @StateObject private var masteryStore: MasteryStore
    @StateObject private var answerOverridesStore: AnswerOverridesStore
    @StateObject private var practiceController: PracticeWindowController
    @StateObject private var zetamacStore: ZetamacStore
    @StateObject private var zetamacController: ZetamacWindowController
    @StateObject private var leetCodeStore: LeetCodeStore
    @StateObject private var leetCodeController: LeetCodeWindowController
    @StateObject private var recallStore: RecallStore
    @StateObject private var recallController: RecallWindowController

    init() {
        // Must observe before focusContainer (lazy) starts mirroring, or the setup event is missed.
        CloudSyncMonitor.shared.start()
        runOneShotMigration()
        StoreBackup.runDailyIfNeeded(container: focusContainer)
        // Menu-bar apps can stay open for days; re-check so each day still gets a backup.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                StoreBackup.runDailyIfNeeded(container: focusContainer)
            }
        }

        let store = SessionStore(container: focusContainer)
        let appSettings = AppSettings()
        let timer = TimerManager()
        timer.recoverPartialSession(into: store)
        timer.sessionStore = store
        store.runningSince = { [weak timer] in timer?.isActive == true ? timer?.sessionStartTime : nil }
        timer.settings = appSettings
        timer.applySettings()
        let stateSync = TimerStateSync(container: focusContainer)
        timer.stateSync = stateSync
        timer.localBroadcast = LocalTimerBroadcast(deviceID: stateSync.deviceID)

        // Construct stores that other stores depend on FIRST so we can
        // share one instance (rather than two HomeworkStores with separate
        // ModelContexts diverging on @Published caches).
        let homework = HomeworkStore(container: focusContainer)
        let mastery = MasteryStore(container: focusContainer)

        _sessionStore        = StateObject(wrappedValue: store)
        _settings            = StateObject(wrappedValue: appSettings)
        _timerManager        = StateObject(wrappedValue: timer)
        let problems = ProblemStore(container: focusContainer)
        _problemStore        = StateObject(wrappedValue: problems)
        _homeworkStore       = StateObject(wrappedValue: homework)
        let scratch = ScratchStore(container: focusContainer)
        let health = HealthStore(container: focusContainer)
        _scratchStore        = StateObject(wrappedValue: scratch)
        _healthStore         = StateObject(wrappedValue: health)
        let days = DayStore(container: focusContainer)
        let dashboard = DashboardWindowController()
        _dayStore            = StateObject(wrappedValue: days)
        _dashboardController = StateObject(wrappedValue: dashboard)
        let practice = PracticeStore(container: focusContainer, homeworkStore: homework)
        practice.attach(masteryStore: mastery)
        _practiceStore       = StateObject(wrappedValue: practice)
        _masteryStore        = StateObject(wrappedValue: mastery)
        let answerOverrides = AnswerOverridesStore()
        _answerOverridesStore = StateObject(wrappedValue: answerOverrides)
        let practiceCtrl = PracticeWindowController()
        _practiceController  = StateObject(wrappedValue: practiceCtrl)
        let zetamac = ZetamacStore()
        _zetamacStore        = StateObject(wrappedValue: zetamac)
        let zetamacCtrl = ZetamacWindowController()
        _zetamacController   = StateObject(wrappedValue: zetamacCtrl)
        let onboarding = OnboardingWindowController()
        _onboardingController = StateObject(wrappedValue: onboarding)
        let leetCode = LeetCodeStore(catalog: .shared, problemStore: problems, settings: appSettings)
        leetCode.onStartPractice = { [weak timer] in timer?.switchTo(FocusCategories.leetCode) }
        leetCode.connectPractice(timer: timer)
        let leetCodeCtrl = LeetCodeWindowController()
        _leetCodeStore       = StateObject(wrappedValue: leetCode)
        _leetCodeController  = StateObject(wrappedValue: leetCodeCtrl)
        let recall = RecallStore(container: focusContainer)
        let recallCtrl = RecallWindowController()
        _recallStore         = StateObject(wrappedValue: recall)
        _recallController    = StateObject(wrappedValue: recallCtrl)
        timer.onFocusSegmentSaved = { session in
            guard appSettings.recallAfterSession, session.isFocus,
                  session.durationMinutes >= Double(appSettings.recallMinMinutes) else { return }
            DispatchQueue.main.async {
                RecallPanel.shared.show(session: session, store: recall, settings: appSettings)
            }
        }

        SiteBlocker.cleanupIfNeeded()

        let browser = BrowserStore(container: focusContainer)
        _browserStore        = StateObject(wrappedValue: browser)
        BrowserBridge.shared.stateProvider = {
            BrowserBridge.State(
                blocking: timer.shouldBlockSites,
                domains: appSettings.blockedSites.map(SiteBlocker.cleanDomain).filter { !$0.isEmpty },
                label: timer.isOnBreak ? "Break" : timer.currentLabel,
                isFocus: timer.isFocusRunning,
                onBreak: timer.isActive && timer.isOnBreak,
                paused: timer.isActive && !timer.isRunning,
                bypassAllowed: !timer.isFocusRunning,
                sessionStart: timer.sessionStartTime.map { $0.timeIntervalSince1970 * 1000 },
                todayBlocked: browser.blockCount(since: Calendar.current.startOfDay(for: Date())),
                darkPages: .init(mode: appSettings.darkPagesMode, from: appSettings.darkPagesFrom, to: appSettings.darkPagesTo,
                                 brightness: appSettings.darkPagesBrightness, contrast: appSettings.darkPagesContrast)
            )
        }
        BrowserBridge.shared.onEvents = { browser.ingest($0) }
        BrowserBridge.shared.onDarkPages = { dark in
            appSettings.darkPagesMode = dark.mode
            appSettings.darkPagesFrom = dark.from
            appSettings.darkPagesTo = dark.to
            appSettings.darkPagesBrightness = dark.brightness
            appSettings.darkPagesContrast = dark.contrast
        }
        BrowserBridge.shared.onReaderSave = { url, title, source in
            await ReaderStore.shared.save(url: url, title: title, label: timer.isOnBreak ? "Break" : timer.currentLabel,
                                          wasFocus: timer.isFocusRunning, source: source)
        }
        Task { @MainActor in await ReaderStore.shared.uploadPending() }
        BrowserBridge.shared.observeDarkPages(appSettings)
        BrowserBridge.shared.start()

        CommitmentReminder.shared.install(dayStore: days, settings: appSettings) {
            EveningReviewWindowController.shared.open(store: store, days: days, settings: appSettings, timer: timer, recall: recall)
        }
        CommitmentReminder.shared.onOtherTap = { id in
            if id == LeetCodeStore.nudgeID { leetCodeCtrl.open(store: leetCode, settings: appSettings) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if !appSettings.hasCompletedOnboarding {
                    onboarding.open(settings: appSettings)
                }
                // Restore windows that were open at the previous quit. The
                // active-problem snapshot (PracticeStore) and last-results
                // history (ZetamacStore) are already rehydrated from disk;
                // this just brings their windows back so the user lands
                // where they left off rather than having to navigate from
                // the popover every relaunch.
                if PracticeWindowController.wasOpenAtQuit {
                    practiceCtrl.open(store: practice,
                                      homeworkStore: homework,
                                      masteryStore: mastery,
                                      answerOverridesStore: answerOverrides)
                }
                if ZetamacWindowController.wasOpenAtQuit {
                    zetamacCtrl.open(store: zetamac)
                }
            }
        }

        QuickSwitch.shared = QuickSwitch(timer: timer, settings: appSettings, days: days)
        QuickSwitch.shared?.openDashboard = {
            dashboard.open(sessionStore: store, problemStore: problems, homeworkStore: homework,
                           settings: appSettings, dayStore: days, timerManager: timer, browserStore: browser)
        }
        if appSettings.needsCommitmentToday, let text = days.todayRecord?.commitmentText, !text.isEmpty {
            appSettings.markCommitmentDone(text: text)
        }
        AwayCoach.shared = AwayCoach(timer: timer, store: store, settings: appSettings, days: days)
        ScreenCoach.shared = ScreenCoach(timer: timer, settings: appSettings, days: days)
        FocusModes.shared.start(timer: timer)
        CoachDayWorker.shared.start(store: store, days: days, settings: appSettings)
        DayBriefPublisher.shared.start(store: store, timer: timer, settings: appSettings)
        QuickSwitch.shared?.openGallery = { name, dark in
            switch name {
            case "dashboard", "dashboard-review", "dashboard-trends", "dashboard-week":
                DesignGallery.show(
                    DashboardView(sessionStore: store, problemStore: problems, homeworkStore: homework, settings: appSettings,
                                  dayStore: days, timerManager: timer, browserStore: browser,
                                  initialDestination: ["dashboard-trends", "dashboard-week"].contains(name) ? "Week" : "Day"),
                    name: name, dark: dark, size: NSSize(width: 1100, height: 900))
            case "leetcode-working":
                DesignGallery.show(
                    LeetCodeDailyGoalRow(count: 1, newCount: 1, redoCount: 0, minutes: 35, problemGoal: 4,
                        minutesGoal: 120, tracking: true, start: {}, open: {},
                        activeTitle: "Longest Substring Without Repeating Characters", activeSeconds: 1053, done: {}).padding(16),
                    name: name, dark: dark, size: NSSize(width: 360, height: 310))
            case "leetcode-finish", "leetcode-finish-ready", "leetcode-finish-unknown":
                let unknown = name == "leetcode-finish-unknown"
                let problem = LCProblem(number: unknown ? 0 : 3,
                    title: unknown ? "New Practice Problem" : "Longest Substring Without Repeating Characters",
                    slug: unknown ? "new-practice-problem" : "longest-substring-without-repeating-characters",
                    difficulty: .medium, acceptance: 0, paidOnly: false, tags: [],
                    category: unknown ? "" : "Sliding Window", listMask: 0)
                DesignGallery.show(LCLogSheet(problem: problem, suggestedMinutes: unknown ? nil : 18,
                    allowUnsolved: true, workedAt: Date().addingTimeInterval(-1080),
                    previewReady: name == "leetcode-finish-ready", onSave: { _ in true }),
                    name: name, dark: dark, size: NSSize(width: 500, height: 660))
            case "leetcode-goal", "leetcode-goal-done":
                DesignGallery.show(
                    LeetCodeDailyGoalRow(count: name == "leetcode-goal-done" ? 4 : 1,
                        newCount: name == "leetcode-goal-done" ? 3 : 1, redoCount: name == "leetcode-goal-done" ? 1 : 0,
                        minutes: name == "leetcode-goal-done" ? 125 : 35, problemGoal: 4, minutesGoal: 120,
                        tracking: false, start: {}, open: {}).padding(16),
                    name: name, dark: dark, size: NSSize(width: 360, height: 260))
            case "card":
                let m = AwayPromptModel(icon: "eye", title: "Looks like Math", subtitle: "since 8:41 PM · 1m on screen",
                                        question: "Reviewing posets and chains for the MATH 244 midterm.",
                                        keep: "Still SWE", options: ["Math"], tags: appSettings.tags)
                DesignGallery.show(AwayPromptView(model: m).padding(20), name: name, dark: dark, size: NSSize(width: 380, height: 220))
            case "review":
                DesignGallery.show(EveningReviewView(store: store, days: days, settings: appSettings, timer: timer, recall: recall) {},
                                   name: name, dark: dark, size: NSSize(width: 620, height: 900))
            case "commitment", "morning-correction":
                DesignGallery.show(CommitmentView(settings: appSettings, dayStore: days, store: store, timer: timer,
                                                  isShowing: .constant(true), preview: true),
                                   name: name, dark: dark, size: NSSize(width: 360, height: 850))
            case "yesterday-recall", "yesterday-recall-reveal":
                DesignGallery.show(YesterdayRecallView(
                    recall: recall, store: store, journalShortcut: "",
                    focusCategories: Set(appSettings.tags).subtracting(appSettings.lifeTags),
                    coursePrefixes: ClassCalendar.shared.coursePrefixes, onFillGaps: {}, onDone: {},
                    previewRecord: .galleryPreview, previewRevealed: name == "yesterday-recall-reveal"),
                    name: name, dark: dark, size: NSSize(width: 360, height: 760))
            case "leetcode-draft", "leetcode-draft-ready":
                DesignGallery.show(LeetCodeSolveDraftCard(title: "Longest Substring Without Repeating Characters",
                    minutes: name == "leetcode-draft-ready" ? 18 : nil,
                    previewConfidence: name == "leetcode-draft-ready" ? .solid : nil,
                    confirm: { _, _ in }, dismiss: {}).padding(20),
                    name: name, dark: dark, size: NSSize(width: 380, height: 470))
            case "adderall-day":
                DesignGallery.show(ScrollView { AdderallDayView(store: health, preview: true).padding(16) },
                                   name: name, dark: dark, size: NSSize(width: 380, height: 1000))
            case "next-block":
                DesignGallery.show(ScrollView {
                    NextBlockEditor(action: .constant(""), category: .constant("Math"), target: .constant(""),
                        tags: appSettings.tags, suggestion: .init(action: "Work through one example of a partial order",
                        category: "Math", source: "Your start-with note")).padding(16)
                }, name: name, dark: dark, size: NSSize(width: 360, height: 530))
            case "trust-scorecard":
                DesignGallery.show(ScrollView { TrustScorecardView(watcher: ScreenWatcher.shared, day: Date(), sessions: [], preview: true).padding(16) },
                                   name: name, dark: dark, size: NSSize(width: 620, height: 690))
            case "where-was-i":
                DesignGallery.show(VStack(alignment: .leading, spacing: 12) {
                    WhereWasIRow(line: .init(text: "Last time on MATH 244 (12:52 PM): Inclusion–exclusion for ball distributions; you asked: Why inclusion-exclusion on (b) but not (c)?", url: nil, bundle: "com.openai.chat", topic: "Inclusion–exclusion for ball distributions", end: Date().addingTimeInterval(-7200)), color: categoryColor("Math"))
                    WhereWasIRow(line: .init(text: "Last time on SWE (Tue 4:50 PM): Two Sum with a hash map", url: URL(string: "https://leetcode.com/problems/two-sum/"), bundle: "com.google.Chrome", topic: "Two Sum with a hash map", end: Date().addingTimeInterval(-3600)), color: categoryColor("SWE"))
                }.padding(16), name: name, dark: dark, size: NSSize(width: 360, height: 160))
            case "learned-labels":
                DesignGallery.show(ScrollView { LearnedLabelReviewView(preview: true).padding(16) },
                                   name: name, dark: dark, size: NSSize(width: 360, height: 650))
            default:
                var spec = name.replacingOccurrences(of: "popover-", with: "")
                let detent: TimerView.Detent? = switch spec.last {
                case "s": .small
                case "l": .large
                default: nil
                }
                if detent != nil { spec.removeLast() }
                let tab = Int(spec) ?? 0
                DesignGallery.show(
                    PopoverContent(
                        timerManager: timer, sessionStore: store, settings: appSettings, problemStore: problems,
                        homeworkStore: homework, scratchStore: scratch, healthStore: health, dayStore: days,
                        practiceStore: practice, homeworkStoreForPractice: homework, zetamacStore: zetamac,
                        leetCodeStore: leetCode, recallStore: recall,
                        openDashboard: {}, openOnboarding: {}, openPractice: {}, openZetamac: {}, openLeetCode: {},
                        openRecall: {}, initialTab: tab, initialDetent: detent
                    ).modelContainer(focusContainer),
                    name: name, dark: dark, size: NSSize(width: 360, height: tab == 0 ? (detent == .large ? 740 : 460) : 680))
            }
        }
        QuickSwitch.shared?.openReview = {
            EveningReviewWindowController.shared.open(store: store, days: days, settings: appSettings, timer: timer, recall: recall)
        }
        QuickSwitch.shared?.openRecall = {
            recallCtrl.open(store: recall, settings: appSettings, sessionStore: store)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            timer.saveOnQuit()
            MainActor.assumeIsolated { ScreenWatcher.shared.save() }
            if SiteBlocker.hasStaleEntries() { SiteBlocker.unblockAll() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContent(
                timerManager: timerManager,
                sessionStore: sessionStore,
                settings: settings,
                problemStore: problemStore,
                homeworkStore: homeworkStore,
                scratchStore: scratchStore,
                healthStore: healthStore,
                dayStore: dayStore,
                practiceStore: practiceStore,
                homeworkStoreForPractice: homeworkStore,
                zetamacStore: zetamacStore,
                leetCodeStore: leetCodeStore,
                recallStore: recallStore,
                openDashboard: { [self] in
                    dashboardController.open(
                        sessionStore: sessionStore,
                        problemStore: problemStore,
                        homeworkStore: homeworkStore,
                        settings: settings,
                        dayStore: dayStore,
                        timerManager: timerManager,
                        browserStore: browserStore
                    )
                },
                openOnboarding: { [self] in
                    onboardingController.open(settings: settings)
                },
                openPractice: { [self] in
                    practiceController.open(store: practiceStore,
                                            homeworkStore: homeworkStore,
                                            masteryStore: masteryStore,
                                            answerOverridesStore: answerOverridesStore)
                },
                openZetamac: { [self] in
                    zetamacController.open(store: zetamacStore)
                },
                openLeetCode: { [self] in
                    leetCodeController.open(store: leetCodeStore, settings: settings)
                },
                openRecall: { [self] in
                    recallController.open(store: recallStore, settings: settings, sessionStore: sessionStore)
                }
            )
            .modelContainer(focusContainer)
        } label: {
            if timerManager.isActive {
                TimerTicking(clock: timerManager.clock) {
                    Text("\(timerManager.isOnBreak ? "Break" : timerManager.currentLabel)  \(timerManager.menuBarTimeText)")
                }
            } else {
                Image(nsImage: MenuBarRing.mark)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct PopoverContent: View {
    @ObservedObject var timerManager: TimerManager
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var problemStore: ProblemStore
    @ObservedObject var homeworkStore: HomeworkStore
    @ObservedObject var scratchStore: ScratchStore
    @ObservedObject var healthStore: HealthStore
    @ObservedObject var dayStore: DayStore
    @ObservedObject var practiceStore: PracticeStore
    @ObservedObject var homeworkStoreForPractice: HomeworkStore
    @ObservedObject var zetamacStore: ZetamacStore
    @ObservedObject var leetCodeStore: LeetCodeStore
    @ObservedObject var recallStore: RecallStore
    let openDashboard: () -> Void
    let openOnboarding: () -> Void
    let openPractice: () -> Void
    let openZetamac: () -> Void
    let openLeetCode: () -> Void
    let openRecall: () -> Void
    /// Gallery screenshots open a given page and sheet size.
    var initialTab: Int? = nil
    var initialDetent: TimerView.Detent? = nil

    @State private var selectedTab = 0
    @AppStorage("quickPanelDetails") private var expandedStored = false
    @AppStorage("quickPanelCompactResetV2") private var didResetToCompact = false
    /// Gallery shots set this instead of the stored size, so a screenshot
    /// never changes how your own popover opens.
    @State private var detentOverride: TimerView.Detent?
    @State private var showYesterdayRecall = false
    @State private var showCommitment = false
    @State private var reviewTarget: DayRecord? = nil
    @State private var showDayReview = false
    // Prevents onAppear re-triggering commitment (and microphone requests) after each session end
    @AppStorage("lastCommitmentPromptDay") private var lastCommitmentPromptDay: Double = 0

    var body: some View {
        popoverBody
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
            .background(PopoverWindowFitter())
            .popoverPanel(tint: washColor)
            .onAppear {
                if let initialTab { selectedTab = initialTab }
                if let initialDetent { detentOverride = initialDetent }
                if initialDetent == nil && !didResetToCompact {
                    expandedStored = false
                    didResetToCompact = true
                }
                // Force "today"-scoped views to re-evaluate every time the
                // popover opens. Without this, a menu-bar app that's been
                // running since yesterday would still display yesterday's
                // dayStart, today-focus minutes, etc. — the underlying
                // computeds are correct, but SwiftUI doesn't know to call
                // them again until an @Published fires.
                sessionStore.touchForToday()
                dayStore.touchForToday()

                // Backfill today's DayRecord with settings.todayCommitment
                // for installs that committed before commitment history was
                // tracked per-day. Idempotent: only runs if the record has
                // no text yet.
                if !settings.needsCommitmentToday,
                   !settings.todayCommitment.isEmpty,
                   (dayStore.todayRecord?.commitmentText ?? "").isEmpty {
                    dayStore.setCommitment(text: settings.todayCommitment)
                }

                // The reverse: today's record has the commitment (made here or
                // on the iPad) but the synced date says otherwise. Re-mark it,
                // which also pushes the right date to the other devices.
                if settings.needsCommitmentToday,
                   let text = dayStore.todayRecord?.commitmentText, !text.isEmpty {
                    settings.markCommitmentDone(text: text)
                }

                let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                if dayStore.isDayStarted && settings.needsCommitmentToday
                    && lastCommitmentPromptDay < todayStart {
                    lastCommitmentPromptDay = todayStart
                    showCommitment = true
                }
                // Catch unreviewed past commitments — surfaces a Yes/No prompt
                // for yesterday (or earlier) so the streak stays honest. Only
                // when the morning commitment isn't currently in the way.
                if !showCommitment, let pending = dayStore.pendingReviewDay() {
                    reviewTarget = pending
                }
            }
    }

    private var practiceElapsedShort: String {
        let s = Int(practiceStore.elapsedSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// MM:SS countdown for the active Math Sprint, surfaced on the
    /// popover button so the user can see at a glance the game is alive
    /// (without reopening the window).
    private var zetamacLiveTimeShort: String {
        let s = zetamacStore.liveSecondsLeft
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var washColor: Color {
        guard dayState == .open, selectedTab == 0 else { return .clear }
        if timerManager.isActive && timerManager.isOnBreak { return TimerView.breakBlue }
        return timerManager.currentLabel.isEmpty ? .clear : categoryColor(timerManager.currentLabel)
    }

    private var moreItems: [TimerView.MoreItem] {
        let lc = leetCodeStore
        let lcBadge = lc.activeProblem.map { "#\($0.number)" } ?? "\(lc.todayCount)/\(lc.dailyGoal)"
        return [
            .init(title: "Settings", icon: "gearshape") { selectedTab = 4 },
            .init(title: "LeetCode", icon: "chevron.left.forwardslash.chevron.right", badge: lcBadge, divider: true, action: openLeetCode),
            .init(title: "Practice", icon: "scope",
                  badge: practiceStore.isActive ? practiceElapsedShort : (dueReviewBadge > 0 ? "\(dueReviewBadge) due" : nil),
                  action: openPractice),
            .init(title: "Recall", icon: "brain.head.profile", badge: recallDue > 0 ? "\(recallDue) due" : nil, action: openRecall),
            .init(title: "Math Sprint", icon: "plus.forwardslash.minus",
                  badge: zetamacStore.isGameActive ? zetamacLiveTimeShort : (zetamacStore.bestScore > 0 ? "best \(zetamacStore.bestScore)" : nil),
                  action: openZetamac),
            .init(title: "Dashboard", icon: "rectangle.grid.2x2", action: openDashboard),
            .init(title: "End Day", icon: "moon", divider: true) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { dayStore.endDay() }
                if dayStore.todayCommitmentNeedsReview, let r = dayStore.todayRecord {
                    reviewTarget = r
                }
                openDashboard()
            },
            .init(title: "Quit Focus", icon: "power") { NSApplication.shared.terminate(nil) },
        ]
    }

    private var dueReviewBadge: Int { homeworkStoreForPractice.dueForReview.count }
    private var recallDue: Int { recallStore.dueCount(cap: settings.recallDailyCap) }

    private var needsYesterdayRecall: Bool {
        settings.morningRecall && recallStore.needsYesterdayRecall(sessionStore: sessionStore)
    }

    private var dayState: DayGateState {
        if dayStore.isDayEnded { return .closed }
        if dayStore.isDayStarted { return .open }
        return .unopened
    }

    private var popoverBody: some View {
        ZStack {
            Group {
                switch dayState {
                case .unopened:
                    DayOpenCoverView(
                        dayStore: dayStore,
                        settings: settings,
                        sessionStore: sessionStore,
                        onReviewYesterday: {
                            if needsYesterdayRecall { showYesterdayRecall = true } else { showDayReview = true }
                        },
                        onBegin: {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                                dayStore.startDay()
                            }
                            if needsYesterdayRecall {
                                showYesterdayRecall = true
                            } else if settings.commitmentEnabled && settings.needsCommitmentToday {
                                showCommitment = true
                            }
                        }
                    )
                    .frame(height: 600)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .closed:
                    DayClosedCoverView(
                        dayStore: dayStore,
                        sessionStore: sessionStore,
                        settings: settings,
                        onReopen: {
                            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                                dayStore.reopenDay()
                            }
                        }
                    )
                    .frame(height: 600)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .open:
                    openBookContent
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: dayState)
            .onChange(of: showDayReview) { _, open in
                if !open && dayStore.isDayStarted && settings.commitmentEnabled && settings.needsCommitmentToday {
                    showCommitment = true
                }
            }

            if showCommitment {
                CommitmentView(settings: settings, dayStore: dayStore, store: sessionStore, timer: timerManager,
                               isShowing: $showCommitment)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    .zIndex(10)
            }

            if showDayReview {
                DayReviewView(store: sessionStore, settings: settings, timer: timerManager, isShowing: $showDayReview)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    .zIndex(12)
            }

            if showYesterdayRecall {
                YesterdayRecallView(
                    recall: recallStore,
                    store: sessionStore,
                    journalShortcut: settings.journalShortcut,
                    focusCategories: Set(settings.tags).subtracting(settings.lifeTags),
                    coursePrefixes: ClassCalendar.shared.coursePrefixes,
                    onFillGaps: {
                        showYesterdayRecall = false
                        showDayReview = true
                    },
                    onDone: {
                        showYesterdayRecall = false
                        if dayStore.isDayStarted && settings.commitmentEnabled && settings.needsCommitmentToday {
                            showCommitment = true
                        }
                    }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                .zIndex(13)
            }

            if let target = reviewTarget {
                CommitmentReviewView(
                    dayStore: dayStore,
                    day: target,
                    isShowing: Binding(
                        get: { reviewTarget != nil },
                        set: { if !$0 { reviewTarget = nil } }
                    )
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                .zIndex(11)
            }

            // On the covers there's no More menu, so Quit sits in the corner.
            if dayState != .open { VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button("Quit Focus") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            } }
        }
    }

    private var pageTitle: String {
        switch selectedTab {
        case 1: "Stats"
        case 2: "Problems"
        case 3: "Notes"
        case 5: "Health"
        default: "Settings"
        }
    }

    private var dashboardButton: some View {
        Button(action: openDashboard) {
            Image(systemName: "rectangle.grid.2x2").font(.system(size: 13, weight: .medium))
        }
        .modifier(NativeGlassControl(prominent: false, tint: .accentColor))
        .help("Dashboard")
    }

    private var openBookContent: some View {
        VStack(spacing: 0) {
            if selectedTab != 0 {
                HStack {
                    Text(pageTitle).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    dashboardButton
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            if selectedTab == 0 {
                TimerView(
                    timer: timerManager, store: sessionStore, settings: settings, dayStore: dayStore,
                    health: healthStore, leetCode: leetCodeStore, onOpenLeetCode: openLeetCode, showDayReview: $showDayReview,
                    detent: Binding(get: { detentOverride ?? (expandedStored ? .large : .small) },
                                    set: { if detentOverride != nil { detentOverride = $0 } else { expandedStored = $0 == .large } }),
                    onOpenDose: { UserDefaults.standard.set(HealthTracker.adderall.rawValue, forKey: "healthTracker"); selectedTab = 5 }
                )
                .overlay(alignment: .topTrailing) { dashboardButton.padding(.trailing, 16).padding(.top, 14) }
            } else {
                Group {
                    switch selectedTab {
                    case 1: StatsView(store: sessionStore, settings: settings)
                    case 2: ProblemsView(store: problemStore, homeworkStore: homeworkStore, settings: settings)
                    case 3: ScratchpadView(store: scratchStore)
                    case 5: HealthView(store: healthStore, sessionStore: sessionStore)
                    default: SettingsView(settings: settings, timer: timerManager, store: sessionStore, openOnboarding: openOnboarding)
                    }
                }
                .frame(height: 540)
            }
            PageBar(selected: $selectedTab, more: moreItems)
        }
    }
}

/// The popover's tab bar (iOS style: icon over a caption), so every page is
/// one click away. More holds Settings and the tool windows.
struct PageBar: View {
    @Binding var selected: Int
    let more: [TimerView.MoreItem]
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [(tag: Int, title: String, icon: String)] = [
        (0, "Now", "timer"), (1, "Stats", "chart.bar"), (2, "Problems", "list.bullet.rectangle"),
        (3, "Notes", "square.and.pencil"), (5, "Health", "heart"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(pages, id: \.tag) { p in
                Button { selected = p.tag } label: { item(p.title, p.icon, on: selected == p.tag) }
                    .buttonStyle(.plain)
                    .help(p.title)
            }
            Menu {
                ForEach(more) { m in
                    if m.divider { Divider() }
                    Button { m.action() } label: {
                        Label(m.badge.map { "\(m.title)  \($0)" } ?? m.title, systemImage: m.icon)
                    }
                }
            } label: {
                item("More", "ellipsis.circle", on: selected == 4)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Settings, LeetCode, Practice, Recall, Math Sprint, Dashboard, End Day")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: selected)
    }

    private func item(_ title: String, _ icon: String, on: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: on ? icon + (icon.hasSuffix(".circle") ? ".fill" : "") : icon)
                .font(.system(size: 16, weight: on ? .semibold : .regular))
                .frame(height: 20)
            Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
        }
        .foregroundStyle(on ? Color.primary : Color.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.primary.opacity(0.06))
                    .matchedGeometryEffect(id: "selected-page", in: selectionNamespace)
            }
        }
        .contentShape(Rectangle())
    }
}

enum MenuBarRing {
    /// The app icon's mark (an eye looking down at three tape cells, the middle one solid),
    /// as a template for the idle menu bar. Drawn on a 100-unit grid, y down.
    static let mark: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { rect in
            let u: CGFloat = 0.205
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: rect.midX + (x - 50) * u, y: rect.midY + (y - 52.5) * u)
            }
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(origin: p(x, y), size: NSSize(width: w * u, height: h * u))
            }
            let eye = NSBezierPath()
            eye.move(to: p(14, 36))
            eye.curve(to: p(86, 36), controlPoint1: p(28, 16), controlPoint2: p(72, 16))
            eye.curve(to: p(14, 36), controlPoint1: p(72, 56), controlPoint2: p(28, 56))
            eye.close()
            eye.lineWidth = 8 * u
            eye.lineJoinStyle = .round
            NSColor.black.setStroke()
            eye.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: box(40.5, 32, 19, 19)).fill()
            for (x, alpha) in [(CGFloat(13), 0.38), (39, 1), (65, 0.38)] {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: box(x, 68, 22, 20), xRadius: 5.5 * u, yRadius: 5.5 * u).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
