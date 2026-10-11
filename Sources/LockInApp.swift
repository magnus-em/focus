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
        _scratchStore        = StateObject(wrappedValue: ScratchStore(container: focusContainer))
        _healthStore         = StateObject(wrappedValue: HealthStore(container: focusContainer))
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

        CommitmentReminder.shared.install(dayStore: days, settings: appSettings) {
            dashboard.open(sessionStore: store, problemStore: problems, homeworkStore: homework,
                           settings: appSettings, dayStore: days, timerManager: timer)
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
        QuickSwitch.shared?.openRecall = {
            recallCtrl.open(store: recall, settings: appSettings, sessionStore: store)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            timer.saveOnQuit()
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
                        timerManager: timerManager
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
                Text(timerManager.menuBarTimeText)
            } else {
                Image(systemName: "scope")
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

    @State private var selectedTab = 0
    @State private var showYesterdayRecall = false
    @State private var showCommitment = false
    @State private var reviewTarget: DayRecord? = nil
    @State private var showDayReview = false
    // Prevents onAppear re-triggering commitment (and microphone requests) after each session end
    @AppStorage("lastCommitmentPromptDay") private var lastCommitmentPromptDay: Double = 0

    var body: some View {
        popoverBody
            .frame(width: 300)
            .popoverBackground()
            .onAppear {
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

    private func launcherTile(icon: String, title: String, badge: String?, badgeColor: Color? = nil,
                              tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 16)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(badge ?? " ")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(badgeColor ?? Color.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var launcherRow: some View {
        let orange = Color(red: 0.98, green: 0.63, blue: 0.16)
        let blue = Color(red: 0.27, green: 0.62, blue: 0.83)
        let green = Color(red: 0.25, green: 0.72, blue: 0.53)
        let lc = leetCodeStore
        let lcBadge: String = {
            if let p = lc.activeProblem { return "#\(p.number)" }
            return "\(lc.todayCount)/\(lc.dailyGoal)" + (lc.streak > 0 ? " · \(lc.streak)🔥" : "")
        }()
        let lcBadgeColor: Color = lc.activeProblem == nil && lc.todayCount >= lc.dailyGoal ? .green
            : (lc.streakAtRisk ? .red : orange)
        return HStack(spacing: 6) {
            launcherTile(icon: "chevron.left.forwardslash.chevron.right", title: "LeetCode",
                         badge: lcBadge, badgeColor: lcBadgeColor, tint: orange,
                         help: lc.activeProblem.map { "LeetCode · #\($0.number) \($0.title)" } ?? "Open LeetCode",
                         action: openLeetCode)
            launcherTile(icon: "scope", title: "Practice",
                         badge: practiceStore.isActive ? practiceElapsedShort
                             : (dueReviewBadge > 0 ? "\(dueReviewBadge) due" : nil),
                         badgeColor: practiceStore.isActive ? blue : .orange, tint: blue,
                         help: "Open Practice Mode", action: openPractice)
            launcherTile(icon: "brain.head.profile", title: "Recall",
                         badge: recallDue > 0 ? "\(recallDue) due" : nil,
                         badgeColor: recallPurple, tint: recallPurple,
                         help: "Open Recall (⌃⌥⌘R)", action: openRecall)
            launcherTile(icon: "plus.forwardslash.minus", title: "Sprint",
                         badge: zetamacStore.isGameActive ? "\(zetamacLiveTimeShort) · \(zetamacStore.liveScore)"
                             : (zetamacStore.bestScore > 0 ? "best \(zetamacStore.bestScore)" : nil),
                         badgeColor: green, tint: green,
                         help: "Open Math Sprint", action: openZetamac)
            launcherTile(icon: "chart.bar.doc.horizontal.fill", title: "Dashboard",
                         badge: nil, tint: .secondary,
                         help: "Open Dashboard", action: openDashboard)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var dueReviewBadge: Int { homeworkStoreForPractice.dueForReview.count }
    private var recallDue: Int { recallStore.dueCount(cap: settings.recallDailyCap) }

    private var needsYesterdayRecall: Bool {
        settings.morningRecall && recallStore.needsYesterdayRecall(sessionStore: sessionStore)
    }

    private func tabChipButton(icon: String, tag: Int, help: String) -> some View {
        let selected = selectedTab == tag
        return Button { selectedTab = tag } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .frame(width: 40, height: 30)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary))
        }
        .buttonStyle(.plain)
        .glassTabChip(selected: selected)
        .help(help)
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
                CommitmentView(settings: settings, dayStore: dayStore, isShowing: $showCommitment)
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

            // Always-available Quit (sits in the lower-right corner whether
            // the day is open or not — the cover gates everything else but
            // shouldn't trap the user in the app).
            VStack {
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
            }
            .allowsHitTesting(true)
        }
    }

    private var openBookContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabChipButton(icon: "timer", tag: 0, help: "Timer")
                tabChipButton(icon: "chart.bar.fill", tag: 1, help: "Stats")
                tabChipButton(icon: "function", tag: 2, help: "Problems")
                tabChipButton(icon: "square.and.pencil", tag: 3, help: "Scratchpad")
                tabChipButton(icon: "heart.fill", tag: 5, help: "Health")
                tabChipButton(icon: "gearshape.fill", tag: 4, help: "Settings")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)

            Group {
                switch selectedTab {
                case 0:
                    GeometryReader { geo in
                        ScrollView(.vertical, showsIndicators: false) {
                            TimerView(
                                timer: timerManager, store: sessionStore, settings: settings,
                                dayStore: dayStore, showCommitment: $showCommitment,
                                reviewTarget: $reviewTarget, showDayReview: $showDayReview
                            )
                            .frame(minHeight: geo.size.height)
                        }
                    }
                case 1: StatsView(store: sessionStore, settings: settings)
                case 2: ProblemsView(store: problemStore, homeworkStore: homeworkStore, settings: settings)
                case 3: ScratchpadView(store: scratchStore)
                case 5: HealthView(store: healthStore, sessionStore: sessionStore)
                default: SettingsView(settings: settings, timer: timerManager, store: sessionStore, openOnboarding: openOnboarding)
                }
            }
            .frame(height: 540)

            Divider()

            launcherRow
                .padding(.bottom, 24)
        }
    }
}
