import AppKit
import Combine
import FocusCore
import SwiftUI

// MARK: - Window controller

class DashboardWindowController: ObservableObject {
    private var window: NSWindow?

    func open(sessionStore: SessionStore, problemStore: ProblemStore, homeworkStore: HomeworkStore, settings: AppSettings, dayStore: DayStore, timerManager: TimerManager, browserStore: BrowserStore) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DashboardView(sessionStore: sessionStore, problemStore: problemStore, homeworkStore: homeworkStore, settings: settings, dayStore: dayStore, timerManager: timerManager, browserStore: browserStore)
        let vc = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: vc)
        w.title = "Focus"
        w.setContentSize(NSSize(width: 1020, height: 740))
        w.minSize = NSSize(width: 740, height: 520)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - Shared log event type

private struct DayEvent: Identifiable {
    enum Kind {
        case focus(WorkSession)
        case breakSession(WorkSession)
        case problem(ProblemEntry)
        case inProgressFocus(start: Date, elapsedMinutes: Double, label: String?)
        case inProgressBreak(start: Date, elapsedMinutes: Double)
    }
    let id: String
    let time: Date
    let kind: Kind
}

// MARK: - Shared formatters

private func fmtMins(_ m: Double) -> String {
    durationText(minutes: m)
}

private func fmtHours(_ h: Double) -> String {
    h >= 1 ? String(format: "%.1fh", h) : "\(Int(h * 60))m"
}

private enum DashboardDestination: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"

    /// Old names still open the page that replaced them.
    init?(name: String) {
        switch name {
        case "Day", "Today", "Review": self = .day
        case "Week", "Trends": self = .week
        default: return nil
        }
    }

    var id: String { rawValue }
    var symbol: String { self == .day ? "text.alignleft" : "calendar" }
}

private struct DayChange {
    let text: String
    let undo: SessionStore.ReviewUndo?
}

private final class DashboardLiveState: ObservableObject {
    struct Snapshot {
        var work: WorkSession?
        var rest: WorkSession?
        var label = ""
        var isActive = false
        var isOnBreak = false
        var runningStart: Date?
    }

    private struct Identity: Equatable {
        let isActive: Bool
        let isRunning: Bool
        let isOnBreak: Bool
        let label: String
        let start: Date?
        let pause: Date?
        let breakKinds: [BreakKind]
    }

    @Published private(set) var snapshot = Snapshot()
    private var identity: Identity?
    private var lastRefresh = Date.distantPast
    private var subscription: AnyCancellable?

    init(timer: TimerManager) {
        refresh(timer)
        // Timer publishes before mutation; receive on the next main-loop turn.
        subscription = timer.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak timer] _ in
            guard let timer else { return }
            self?.refresh(timer)
        }
    }

    private func refresh(_ timer: TimerManager) {
        let next = Identity(isActive: timer.isActive, isRunning: timer.isRunning,
                            isOnBreak: timer.isOnBreak, label: timer.currentLabel,
                            start: timer.sessionStartTime, pause: timer.pauseStartedAt,
                            breakKinds: timer.currentBreakKinds)
        let now = Date()
        guard identity != next || (next.isActive && now.timeIntervalSince(lastRefresh) >= 30) else { return }
        identity = next
        lastRefresh = now
        snapshot = Snapshot(work: timer.currentInProgressSession, rest: timer.currentInProgressBreak,
                            label: timer.currentLabel, isActive: timer.isActive,
                            isOnBreak: timer.isOnBreak, runningStart: timer.sessionStartTime)
    }
}

private struct DashboardDayData {
    var work: [WorkSession] = []
    var breaks: [WorkSession] = []
    var overlappingSessions: [WorkSession] = []
    var reviewSessions: [WorkSession] = []
    var events: [DayEvent] = []
    var problemCount = 0
    var breakMinutes = 0.0

    init() {}

    init(day: Date, sessions: [WorkSession], problems: [ProblemEntry]) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let reviewStart = calendar.date(byAdding: .day, value: -13, to: start)!
        for session in sessions {
            if session.startTime < end && session.startTime.addingTimeInterval(session.durationMinutes * 60) > reviewStart {
                reviewSessions.append(session)
            }
            if session.startTime < end && session.startTime.addingTimeInterval(session.durationMinutes * 60) > start {
                overlappingSessions.append(session)
            }
            guard session.startTime >= start && session.startTime < end else { continue }
            if session.type == .work {
                work.append(session)
                events.append(DayEvent(id: session.id.uuidString, time: session.startTime, kind: .focus(session)))
            } else {
                breaks.append(session)
                breakMinutes += session.durationMinutes
                events.append(DayEvent(id: session.id.uuidString + "-b", time: session.startTime, kind: .breakSession(session)))
            }
        }
        for problem in problems where problem.date >= start && problem.date < end {
            problemCount += 1
            events.append(DayEvent(id: problem.id.uuidString, time: problem.date, kind: .problem(problem)))
        }
        events.sort { $0.time > $1.time }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var problemStore: ProblemStore
    @ObservedObject var homeworkStore: HomeworkStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var dayStore: DayStore
    let timerManager: TimerManager
    private let screenWatcher = ScreenWatcher.shared
    @StateObject private var liveState: DashboardLiveState
    @ObservedObject var browserStore: BrowserStore

    @State private var destination: DashboardDestination = .day
    @StateObject private var dayModel = DayStoryModel()
    @State private var lastChange: DayChange?
    @State private var showTrackedLog = false
    @State private var showTimeline = false
    @State private var showAllTime = false
    @State private var showAccuracy = false
    @State private var dayData = DashboardDayData()
    @State private var editingEvent: DayEvent? = nil
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var reviewTargetForDashboard: DayRecord? = nil

    init(sessionStore: SessionStore, problemStore: ProblemStore, homeworkStore: HomeworkStore,
         settings: AppSettings, dayStore: DayStore, timerManager: TimerManager, browserStore: BrowserStore,
         initialDestination: String = "Today") {
        self.sessionStore = sessionStore
        self.problemStore = problemStore
        self.homeworkStore = homeworkStore
        self.settings = settings
        self.dayStore = dayStore
        self.timerManager = timerManager
        self.browserStore = browserStore
        _destination = State(initialValue: DashboardDestination(name: initialDestination) ?? .day)
        _liveState = StateObject(wrappedValue: DashboardLiveState(timer: timerManager))
    }

    private let red   = Color(red: 0.96, green: 0.36, blue: 0.36)
    private let blue  = Color(red: 0.27, green: 0.62, blue: 0.83)
    private let green = Color(red: 0.25, green: 0.72, blue: 0.53)
    private let amber = Color(red: 0.98, green: 0.70, blue: 0.18)

    private var isSelectedDayToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    /// The week card ends today unless an older day is picked, so clicking
    /// a row inside the week doesn't shift the week under the cursor.
    @State private var weekEndOverride: Date?
    private var weekEndDay: Date { weekEndOverride ?? Calendar.current.startOfDay(for: Date()) }

    private var selectedDayRecord: DayRecord? { dayStore.record(for: selectedDay) }

    private var selectedDayCommitmentText: String? {
        if let t = selectedDayRecord?.commitmentText, !t.isEmpty { return t }
        if isSelectedDayToday, !settings.todayCommitment.isEmpty { return settings.todayCommitment }
        return nil
    }

    @ViewBuilder
    private var selectedDayFulfillmentBadge: some View {
        if let rec = selectedDayRecord, (rec.commitmentText?.isEmpty == false) {
            switch rec.commitmentFulfilled {
            case .some(true):
                commitmentBadge(label: "Done", icon: "checkmark.seal.fill", color: green)
            case .some(false):
                commitmentBadge(label: "Missed", icon: "xmark.seal.fill", color: red)
            case .none:
                Button { reviewTargetForDashboard = rec } label: {
                    commitmentBadge(label: isSelectedDayToday ? "Check in" : "Review",
                                    icon: "questionmark.circle.fill", color: Color.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitmentBadge(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 12))
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var selectedDayFocusSessions: [WorkSession] { dayData.work }
    private var selectedDayBreakSessions: [WorkSession] { dayData.breaks }
    private var selectedDayBreakMinutes: Double { dayData.breakMinutes }
    private var selectedDayProblemCount: Int { dayData.problemCount }

    private var selectedDayEvents: [DayEvent] {
        let calendar = Calendar.current
        var events = dayData.events
        guard isSelectedDayToday else { return events }
        if let live = liveState.snapshot.work, calendar.isDateInToday(live.startTime) {
            events.append(DayEvent(id: "in-progress", time: live.startTime,
                                  kind: .inProgressFocus(start: live.startTime,
                                                         elapsedMinutes: live.durationMinutes, label: live.label)))
        }
        if let live = liveState.snapshot.rest, calendar.isDateInToday(live.startTime) {
            events.append(DayEvent(id: "in-progress-break", time: live.startTime,
                                  kind: .inProgressBreak(start: live.startTime, elapsedMinutes: live.durationMinutes)))
        }
        return events.sorted { $0.time > $1.time }
    }

    private func refreshDayData(sessions: [WorkSession]? = nil, problems: [ProblemEntry]? = nil) {
        dayData = DashboardDayData(day: selectedDay, sessions: sessions ?? sessionStore.sessions,
                                   problems: problems ?? problemStore.problems)
        refreshStory()
    }

    private var focusCategories: Set<String> { Set(settings.tags.filter { !settings.lifeTags.contains($0) }) }

    private func refreshStory() {
        dayModel.refresh(day: selectedDay, sessions: dayData.overlappingSessions, live: selectedDayLiveSessions,
                         focus: focusCategories)
    }

    private var selectedDayFocusMinutes: Double {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay)!
        return (dayData.overlappingSessions + selectedDayLiveSessions).filter(\.isFocus).reduce(0) { sum, s in
            sum + max(0, min(end, s.startTime.addingTimeInterval(s.durationMinutes * 60))
                .timeIntervalSince(max(selectedDay, s.startTime))) / 60
        }
    }

    /// Past time is repainted with Undo; time inside the running block goes
    /// through the timer, so a saved row never overlaps it.
    private func applyFix(_ fix: DayStory.Fix, _ label: String) {
        let saved: String? = label == "Break" ? nil : label
        let runningStart = liveState.snapshot.isActive ? liveState.snapshot.runningStart : nil
        let range = "\(fix.start.formatted(date: .omitted, time: .shortened))–\(fix.running ? "now" : fix.end.formatted(date: .omitted, time: .shortened))"
        var undo: SessionStore.ReviewUndo?
        if let runningStart, fix.end > runningStart {
            if fix.start < runningStart {
                undo = sessionStore.paintForReview(start: fix.start, end: runningStart, label: saved)
            }
            if fix.running || fix.end >= Date().addingTimeInterval(-60) {
                timerManager.switchTo(label, at: max(fix.start, runningStart))
            } else {
                timerManager.carveOut(from: max(fix.start, runningStart), to: fix.end, as: saved)
            }
            lastChange = DayChange(text: "Logged \(range) as \(label).", undo: undo)
        } else if let u = sessionStore.paintForReview(start: fix.start, end: fix.end, label: saved) {
            lastChange = DayChange(text: "Logged \(range) as \(label).", undo: u)
        } else {
            lastChange = DayChange(text: "Couldn't change \(range). Try again, or edit it in the tracked log.", undo: nil)
        }
        refreshStory()
    }

    private func shiftSelectedDay(by days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) {
            let todayStart = Calendar.current.startOfDay(for: Date())
            selectedDay = min(Calendar.current.startOfDay(for: next), todayStart)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            dashboardToolbar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
            HStack(spacing: 0) {
                rightPanel
                if showTrackedLog {
                    Divider()
                    leftPanel.frame(width: 280)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                }
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .topLeading) {
                    LinearGradient(colors: [accent.opacity(0.09), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 360)
                        .allowsHitTesting(false)
                }
        }
        .frame(minWidth: 740, minHeight: 520)
        .onAppear { refreshDayData() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if isSelectedDayToday { refreshStory() }
        }
        .onChange(of: liveState.snapshot.label) { _, _ in refreshStory() }
        .onReceive(sessionStore.$sessions) { refreshDayData(sessions: $0) }
        .onReceive(problemStore.$problems) { refreshDayData(problems: $0) }
        .onChange(of: selectedDay) { _, day in
            refreshDayData()
            let calendar = Calendar.current
            let weekStart = calendar.date(byAdding: .day, value: -6, to: weekEndDay)!
            if day < weekStart || day > weekEndDay {
                weekEndOverride = calendar.isDateInToday(day) ? nil : day
            }
        }
        .sheet(item: $editingEvent) { event in
            EventEditSheet(
                event: event, settings: settings,
                sessionStore: sessionStore, problemStore: problemStore
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommitmentReview)) { note in
            guard let id = note.object as? UUID,
                  let rec = dayStore.records.first(where: { $0.id == id }),
                  rec.commitmentFulfilled == nil else { return }
            selectedDay = rec.calendarDay
            reviewTargetForDashboard = rec
        }
        .sheet(item: $reviewTargetForDashboard) { day in
            CommitmentReviewView(
                dayStore: dayStore,
                day: day,
                isShowing: Binding(
                    get: { reviewTargetForDashboard != nil },
                    set: { if !$0 { reviewTargetForDashboard = nil } }
                )
            )
            .frame(width: 360, height: 320)
        }
    }

    private var accent: Color {
        let snapshot = liveState.snapshot
        guard snapshot.isActive else { return .accentColor }
        return snapshot.isOnBreak ? TimerView.breakBlue : categoryColor(snapshot.label)
    }

    private var weekRangeText: String {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: weekEndDay)!
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(weekEndDay.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(destination == .week ? (Calendar.current.isDateInToday(weekEndDay) ? "This week" : "Week")
                     : isSelectedDayToday ? "Today" : selectedDay.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 26, weight: .semibold))
                Text(destination == .week ? "\(weekRangeText), 7 days" : selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                ForEach(DashboardDestination.allCases) { item in
                    Button { destination = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background {
                                if item == destination {
                                    Capsule().fill(accent.opacity(0.15))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(item == destination ? Color.primary : Color.secondaryText)
                    .help(item == .day ? "One day's story: what you did, what the screen saw, what to fix"
                          : "The last 7 days: courses, exams and days that need fixing")
                    .accessibilityAddTraits(item == destination ? .isSelected : [])
                }
            }
            .padding(4)
            .modifier(FloatingGlass())
            Spacer(minLength: 16)
            HStack(spacing: 0) {
                dayNavButton(systemImage: "chevron.left") { shiftSelectedDay(by: -1) }
                dayNavButton(systemImage: "chevron.right", disabled: isSelectedDayToday) { shiftSelectedDay(by: 1) }
                Divider().frame(height: 20).padding(.horizontal, 4)
                Button { showTrackedLog.toggle() } label: {
                    Label("Tracked log", systemImage: "sidebar.right")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 36)
                        .foregroundStyle(showTrackedLog ? Color.primary : .secondaryText)
                }
                .buttonStyle(.plain)
                .help("Show or hide your tracked log")
                .accessibilityLabel("Show or hide your tracked log")
            }
            .padding(4)
            .modifier(FloatingGlass())
        }
    }

    // MARK: - Left: Selected day's log

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tracked log").font(.system(size: 15, weight: .semibold))
                Text("Your timer sessions and logged problems")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                if let rec = selectedDayRecord, let start = rec.dayStart {
                    HStack(spacing: 3) {
                        Text("Started \(start.formatted(date: .omitted, time: .shortened))")
                        if let end = rec.dayEnd {
                            Text("· ended \(end.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                if let commitText = selectedDayCommitmentText {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{201C}\(commitText)\u{201D}")
                            .font(.system(size: 12).italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        selectedDayFulfillmentBadge
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            let events = selectedDayEvents
            if events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(isSelectedDayToday ? "Nothing logged yet today" : "No activity logged")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            EventRow(event: event, onTap: { editingEvent = event })
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                if selectedDayBreakMinutes >= 1 {
                    Label(fmtMins(selectedDayBreakMinutes), systemImage: "cup.and.saucer")
                        .font(.system(size: 12))
                        .foregroundStyle(blue)
                    Spacer()
                }
                Label("\(selectedDayProblemCount)", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private func dayNavButton(systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let label = systemImage == "chevron.left" ? "Previous day" : "Next day"
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayHeaderString(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today · " + shortDate(d) }
        if cal.isDateInYesterday(d) { return "Yesterday · " + shortDate(d) }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    // MARK: - Right: Stats + insights

    private var liveBlocks: [WorkSession] {
        [liveState.snapshot.work, liveState.snapshot.rest].compactMap { $0 }
    }

    private var liveSessions: [WorkSession] {
        sessionStore.sessions + liveBlocks.map {
            WorkSession(id: $0.id, startTime: $0.startTime,
                        durationMinutes: Date().timeIntervalSince($0.startTime) / 60,
                        type: $0.type, label: $0.label)
        }
    }

    private var selectedDayLiveSessions: [WorkSession] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay)!
        return liveBlocks.filter {
            $0.startTime < end && Date() > selectedDay
        }.map {
            WorkSession(id: $0.id, startTime: $0.startTime,
                        durationMinutes: Date().timeIntervalSince($0.startTime) / 60,
                        type: $0.type, label: $0.label)
        }
    }

    private var selectedDaySessions: [WorkSession] {
        dayData.overlappingSessions + selectedDayLiveSessions
    }

    private var reviewSessions: [WorkSession] {
        dayData.reviewSessions + selectedDayLiveSessions
    }

    private var rightPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                switch destination {
                case .day: dayContent
                case .week: weekContent
                }
            }
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .contentMargins(.bottom, liveState.snapshot.isActive ? 90 : 0, for: .scrollContent)
        .overlay(alignment: .bottom) {
            DashboardFloatingTimer(timer: timerManager).padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var dayContent: some View {
        if let change = lastChange {
            HStack(spacing: 12) {
                Image(systemName: change.undo == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(change.undo == nil ? Color.attention : Color.good)
                Text(change.text).font(.system(size: 13))
                Spacer()
                if let undo = change.undo {
                    Button("Undo") {
                        lastChange = sessionStore.undoReview(undo) ? nil
                            : DayChange(text: "Couldn't undo: the log changed since.", undo: nil)
                        refreshStory()
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                Button { lastChange = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.secondaryText).help("Dismiss").accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        }
        DayStoryPage(model: dayModel, day: selectedDay, focusMinutes: selectedDayFocusMinutes,
                     goalHours: Double(settings.dailyGoal), commitment: selectedDayCommitmentText,
                     categories: settings.tags + ["Break"], apply: applyFix,
                     openCoach: { CoachChatWindow.shared.open() })
        if isSelectedDayToday { NextBlockSummary(day: selectedDay) }
        DisclosureGroup(isExpanded: $showTimeline) {
            if showTimeline {
                VStack(alignment: .leading, spacing: 24) {
                    ScreenTimelineSection(watcher: screenWatcher, day: selectedDay, sessions: reviewSessions)
                    ScreenActivitySection(watcher: screenWatcher, day: selectedDay, sessions: selectedDaySessions)
                    dayTimelineSection
                }
                .padding(.top, 12)
            }
        } label: {
            SectionTitle("What the screen saw, minute by minute",
                         subtitle: "Every screenshot's label, the activity log with its notes, and the editable day timeline")
        }
    }

    @ViewBuilder
    private var weekContent: some View {
        WeekPage(endDay: weekEndDay, sessions: liveSessions, live: Set(liveBlocks.map(\.id)), problems: problemStore.problems,
                 focus: focusCategories, settings: settings,
                 onSelectDay: { selectedDay = $0; destination = .day })
        ExamRadarSection(sessions: liveSessions)
        WhereTimeWentSection(store: sessionStore, settings: settings, live: liveBlocks,
                            endDay: weekEndDay, selectedDay: selectedDay,
                            onSelectDay: { selectedDay = $0; destination = .day })
        InsightsSection(watcher: screenWatcher, sessions: sessionStore.sessions)
        DisclosureGroup(isExpanded: $showAccuracy) {
            if showAccuracy {
                VStack(alignment: .leading, spacing: 24) {
                    TrustScorecardView(watcher: screenWatcher, day: selectedDay, sessions: reviewSessions)
                    ScreenReviewSection(
                        watcher: screenWatcher, day: selectedDay, sessions: reviewSessions,
                        runningStart: liveState.snapshot.isActive ? liveState.snapshot.runningStart : nil,
                        paint: { a, b, label in sessionStore.paint(start: a, end: b, label: label == "Break" ? nil : label) }
                    )
                }
                .padding(.top, 12)
            }
        } label: {
            SectionTitle("Tracking accuracy",
                         subtitle: "How often the screen's guesses matched your log, the cards it showed you, and stretches to review")
        }
        DisclosureGroup(isExpanded: $showAllTime) {
            if showAllTime {
                VStack(alignment: .leading, spacing: 24) {
                    DistractionSection(watcher: screenWatcher, day: selectedDay, sessions: reviewSessions)
                    weeklySection
                    focusSplitSection
                    problemProgressSection
                    heatmapSection
                    homeworkHeatmapSection
                    narrativeInsightsSection
                    commitmentHistorySection
                    awardsSection
                    HStack(alignment: .top, spacing: 16) {
                        insightsSection
                        weakAreasSection
                    }
                    browserSection
                    lifetimeSection
                }
                .padding(.top, 12)
            }
        } label: {
            SectionTitle("More charts",
                         subtitle: "Weekly totals, focus split, heatmaps, problems, commitments, awards, browsing and all-time stats")
        }
    }

    // MARK: - 18-week heatmap

    private var heatmapSection: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -(18 * 7 - 1), to: today)!
        let workSessions = sessionStore.sessions.filter { $0.isFocus && $0.startTime >= earliest }
        var minutesByDay: [Date: Double] = [:]
        for s in workSessions {
            let d = cal.startOfDay(for: s.startTime)
            minutesByDay[d, default: 0] += s.durationMinutes
        }
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = ((weekday + 5) % 7)
        let thisWeekMonday = cal.date(byAdding: .day, value: -mondayOffset, to: today)!
        let startDay = cal.date(byAdding: .weekOfYear, value: -17, to: thisWeekMonday)!
        let total = minutesByDay.values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Activity, 18 weeks")
                Spacer()
                Text(fmtHours(total / 60.0))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<18, id: \.self) { w in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cal.date(byAdding: .day, value: w * 7 + d, to: startDay)!
                                heatmapCell(minutes: minutesByDay[cal.startOfDay(for: day)] ?? 0,
                                            isFuture: day > Date())
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach([0.0, 60.0, 120.0, 200.0, 320.0], id: \.self) { m in
                    heatmapSwatch(minutes: m)
                }
                Text("More").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func heatmapCell(minutes: Double, isFuture: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(isFuture ? Color.gray.opacity(0.05) : heatmapColor(minutes))
            .frame(width: 11, height: 11)
    }
    private func heatmapSwatch(minutes: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(heatmapColor(minutes))
            .frame(width: 9, height: 9)
    }
    private func heatmapColor(_ minutes: Double) -> Color {
        if minutes <= 0 { return Color.gray.opacity(0.18) }
        switch minutes {
        case ..<30:   return red.opacity(0.22)
        case ..<90:   return red.opacity(0.40)
        case ..<180:  return red.opacity(0.60)
        case ..<300:  return red.opacity(0.80)
        default:      return red
        }
    }

    // MARK: - Homework heatmap (18 weeks)

    private var homeworkHeatmapSection: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let earliest = cal.date(byAdding: .day, value: -(18 * 7 - 1), to: today)!
        let recent = homeworkStore.items.filter { $0.date >= earliest }
        var countByDay: [Date: Int] = [:]
        for h in recent {
            let d = cal.startOfDay(for: h.date)
            countByDay[d, default: 0] += 1
        }
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = ((weekday + 5) % 7)
        let thisWeekMonday = cal.date(byAdding: .day, value: -mondayOffset, to: today)!
        let startDay = cal.date(byAdding: .weekOfYear, value: -17, to: thisWeekMonday)!
        let total = countByDay.values.reduce(0, +)
        let goal = max(1, settings.homeworkDailyGoal)
        let purple = Color(red: 0.62, green: 0.45, blue: 0.92)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Homework, 18 weeks")
                Spacer()
                Text("\(total) problems")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<18, id: \.self) { w in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cal.date(byAdding: .day, value: w * 7 + d, to: startDay)!
                                let n = countByDay[cal.startOfDay(for: day)] ?? 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day > Date() ? Color.gray.opacity(0.05)
                                          : homeworkCellColor(count: n, goal: goal, base: purple))
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("0").font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach([0, max(1, goal/4), max(2, goal/2), goal, goal * 2], id: \.self) { n in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(homeworkCellColor(count: n, goal: goal, base: purple))
                        .frame(width: 9, height: 9)
                }
                Text("goal+").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func homeworkCellColor(count: Int, goal: Int, base: Color) -> Color {
        if count <= 0 { return Color.gray.opacity(0.18) }
        let ratio = Double(count) / Double(goal)
        switch ratio {
        case ..<0.25: return base.opacity(0.22)
        case ..<0.5:  return base.opacity(0.40)
        case ..<1.0:  return base.opacity(0.65)
        case ..<1.5:  return base.opacity(0.85)
        default:      return base
        }
    }

    // MARK: - Narrative insights ("Wednesday is your power day", etc.)

    private struct NarrativeInsight: Identifiable {
        let id: String
        let kind: Kind
        let headline: String
        let body: String
        enum Kind { case positive, neutral, attention }
    }

    private var narrativeInsightsList: [NarrativeInsight] {
        var out: [NarrativeInsight] = []
        let work = sessionStore.sessions.filter { $0.isFocus }
        let cal = Calendar.current

        // Peak weekday
        if work.count >= 10 {
            var byWeekday: [Int: Double] = [:]
            for s in work {
                let wd = cal.component(.weekday, from: s.startTime)
                byWeekday[wd, default: 0] += s.durationMinutes
            }
            if let best = byWeekday.max(by: { $0.value < $1.value }) {
                let name = cal.weekdaySymbols[best.key - 1]
                out.append(.init(
                    id: "bestDay", kind: .positive,
                    headline: "\(name) is your power day",
                    body: "\(fmtMins(best.value)) of focus on \(name)s overall — your most of any weekday."
                ))
            }

            // Peak hour
            var byHour: [Int: Double] = [:]
            for s in work {
                let h = cal.component(.hour, from: s.startTime)
                byHour[h, default: 0] += s.durationMinutes
            }
            if let best = byHour.max(by: { $0.value < $1.value }) {
                let label: String
                switch best.key {
                case 5..<9:   label = "early-morning"
                case 9..<12:  label = "mid-morning"
                case 12..<14: label = "lunchtime"
                case 14..<17: label = "afternoon"
                case 17..<20: label = "evening"
                case 20..<24: label = "late-evening"
                default:      label = "overnight"
                }
                let mod = best.key % 12 == 0 ? 12 : best.key % 12
                let ampm = best.key < 12 ? "AM" : "PM"
                out.append(.init(
                    id: "peakHour", kind: .neutral,
                    headline: "Your sharpest hour: \(mod) \(ampm)",
                    body: "You do your most focused work in the \(label) block. Try guarding that window."
                ))
            }
        }

        // Week-over-week
        let thisWeek = sessionStore.last7DaysMinutes
        let lastWeek = sessionStore.prior7DaysMinutes
        if lastWeek > 30 {
            let delta = thisWeek - lastWeek
            let pct = delta / lastWeek * 100
            if abs(pct) < 10 {
                out.append(.init(id: "wow-flat", kind: .neutral,
                                 headline: "Steady week",
                                 body: "About the same focus as last week (\(fmtMins(thisWeek)) vs \(fmtMins(lastWeek)))."))
            } else if delta > 0 {
                out.append(.init(id: "wow-up", kind: .positive,
                                 headline: "Up \(Int(pct))% vs last week",
                                 body: "\(fmtMins(thisWeek)) so far this week, up from \(fmtMins(lastWeek)). Momentum."))
            } else {
                out.append(.init(id: "wow-down", kind: .attention,
                                 headline: "Down \(Int(abs(pct)))% vs last week",
                                 body: "\(fmtMins(thisWeek)) vs \(fmtMins(lastWeek)). Worth checking — what's different?"))
            }
        }

        // Consistency dip
        let c7 = sessionStore.consistencyScore(days: 7)
        let c30 = sessionStore.consistencyScore(days: 30)
        if work.count >= 5 {
            if c7 >= 0.9 {
                out.append(.init(id: "consistency-high", kind: .positive,
                                 headline: "Hit every day this week",
                                 body: "\(Int(c7 * 7))/7 of the last week. The habit is working."))
            } else if c7 < c30 - 0.15 {
                out.append(.init(id: "consistency-dip", kind: .attention,
                                 headline: "Consistency dipped this week",
                                 body: "Last 7 days: \(Int(c7 * 100))%. Last 30 days: \(Int(c30 * 100))%. Don't break the chain."))
            }
        }

        return out
    }

    private var narrativeInsightsSection: some View {
        let insights = narrativeInsightsList
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Patterns")
            if insights.isEmpty {
                Text("Log a few more focus sessions and patterns will appear here.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(insights) { insight in
                        HStack(alignment: .top, spacing: 10) {
                            let c = insightColor(insight.kind)
                            ZStack {
                                Circle().fill(c.opacity(0.18)).frame(width: 26, height: 26)
                                Image(systemName: insightIcon(insight.kind))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(c)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.headline)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(insight.body)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func insightColor(_ k: NarrativeInsight.Kind) -> Color {
        switch k {
        case .positive:  return green
        case .neutral:   return blue
        case .attention: return amber
        }
    }
    private func insightIcon(_ k: NarrativeInsight.Kind) -> String {
        switch k {
        case .positive:  return "checkmark.seal.fill"
        case .neutral:   return "info.circle.fill"
        case .attention: return "lightbulb.fill"
        }
    }

    // MARK: - Awards (Fitness-style milestones)

    private struct Award: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let earned: Bool
        let progress: String
    }

    private var allAwards: [Award] {
        let work = sessionStore.sessions.filter { $0.isFocus }
        let totalSessions = work.count
        let totalHours = work.reduce(0) { $0 + $1.durationMinutes } / 60
        let bestStreak = sessionStore.bestStreak
        let bestDayMin = sessionStore.bestDayMinutes

        return [
            .init(id: "first", title: "First Session", subtitle: "Complete one focus session",
                  icon: "flag.fill", earned: totalSessions >= 1,
                  progress: totalSessions >= 1 ? "Earned" : "0/1"),
            .init(id: "ten", title: "Getting Going", subtitle: "10 sessions",
                  icon: "10.circle.fill", earned: totalSessions >= 10,
                  progress: "\(min(totalSessions, 10))/10"),
            .init(id: "hundred", title: "Centurion", subtitle: "100 sessions",
                  icon: "100.circle.fill", earned: totalSessions >= 100,
                  progress: "\(min(totalSessions, 100))/100"),
            .init(id: "10h", title: "Deep End", subtitle: "10 hours",
                  icon: "hourglass.bottomhalf.filled", earned: totalHours >= 10,
                  progress: String(format: "%.0f/10h", min(totalHours, 10))),
            .init(id: "50h", title: "Half a Hundred", subtitle: "50 hours",
                  icon: "hourglass", earned: totalHours >= 50,
                  progress: String(format: "%.0f/50h", min(totalHours, 50))),
            .init(id: "100h", title: "Triple Digits", subtitle: "100 hours",
                  icon: "trophy.fill", earned: totalHours >= 100,
                  progress: String(format: "%.0f/100h", min(totalHours, 100))),
            .init(id: "s3", title: "On a Roll", subtitle: "3-day streak",
                  icon: "flame.fill", earned: bestStreak >= 3,
                  progress: "\(min(bestStreak, 3))/3"),
            .init(id: "s7", title: "Full Week", subtitle: "7-day streak",
                  icon: "flame.fill", earned: bestStreak >= 7,
                  progress: "\(min(bestStreak, 7))/7"),
            .init(id: "s30", title: "Monthly Habit", subtitle: "30-day streak",
                  icon: "flame.circle.fill", earned: bestStreak >= 30,
                  progress: "\(min(bestStreak, 30))/30"),
            .init(id: "d4", title: "Solid Day", subtitle: "4h in one day",
                  icon: "sun.max.fill", earned: bestDayMin >= 240,
                  progress: String(format: "%.1f/4h", min(bestDayMin / 60, 4))),
            .init(id: "d8", title: "Marathon", subtitle: "8h in one day",
                  icon: "sun.horizon.fill", earned: bestDayMin >= 480,
                  progress: String(format: "%.1f/8h", min(bestDayMin / 60, 8))),
            .init(id: "p1", title: "First Solve", subtitle: "Log one problem",
                  icon: "checkmark.circle.fill", earned: problemStore.totalCount >= 1,
                  progress: problemStore.totalCount >= 1 ? "Earned" : "0/1"),
            .init(id: "p50", title: "Pattern Recognizer", subtitle: "50 problems",
                  icon: "brain.head.profile", earned: problemStore.totalCount >= 50,
                  progress: "\(min(problemStore.totalCount, 50))/50"),
            .init(id: "p200", title: "Quant Cohort", subtitle: "200 problems",
                  icon: "function", earned: problemStore.totalCount >= 200,
                  progress: "\(min(problemStore.totalCount, 200))/200"),
        ]
    }

    private var awardsSection: some View {
        let awards = allAwards
        let earned = awards.filter(\.earned).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Awards")
                Spacer()
                Text("\(earned) / \(awards.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(awards) { a in
                    awardTile(a)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func awardTile(_ a: Award) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(a.earned ? amber.opacity(0.2) : Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: a.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(a.earned ? amber : .secondary)
                    .opacity(a.earned ? 1 : 0.5)
            }
            Text(a.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(a.earned ? .primary : .secondary)
            Text(a.progress)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(a.earned ? AnyShapeStyle(amber) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Day timeline

    private var dayTimelineSection: some View {
        let focus = selectedDayFocusSessions
        let breaks = selectedDayBreakSessions

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Day timeline")
                Spacer()
                Text(dayHeaderString(selectedDay))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            DayTimelineCanvas(
                day: selectedDay,
                focus: focus,
                breaks: breaks,
                livefocus: isSelectedDayToday ? liveState.snapshot.work : nil,
                liveBreak: isSelectedDayToday ? liveState.snapshot.rest : nil,
                red: red, blue: blue,
                tags: settings.tags,
                screen: screenWatcher.spans(from: Calendar.current.startOfDay(for: selectedDay),
                                            to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: selectedDay))!),
                onFill: { start, end, label in
                    sessionStore.addSession(WorkSession(
                        startTime: start, durationMinutes: end.timeIntervalSince(start) / 60,
                        type: label == nil ? .shortBreak : .work, label: label
                    ))
                }
            )
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - Browser (Chrome extension)

    private var selectedDayFocusIntervals: [DateInterval] {
        var sessions = selectedDayFocusSessions.filter(\.isFocus)
        if isSelectedDayToday, let live = liveState.snapshot.work, live.isFocus { sessions.append(live) }
        return sessions.map { DateInterval(start: $0.startTime, duration: max(0, $0.durationMinutes * 60)) }
    }

    @ViewBuilder
    private var browserSection: some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let blocks = browserStore.blocks(on: selectedDay)
        let daySpans = browserStore.spans(from: dayStart, to: dayEnd)
        let byDomain = browserStore.secondsByDomain(daySpans)
        let chromeMinutes = daySpans.reduce(0) { $0 + $1.seconds } / 60
        let focusSpans = browserStore.spans(within: selectedDayFocusIntervals)
        let focusByDomain = browserStore.secondsByDomain(focusSpans)
        let focusHours = selectedDayFocusIntervals.reduce(0) { $0 + $1.duration } / 3600
        let blockedSet = Set(settings.blockedSites.map(SiteBlocker.cleanDomain))

        if !blocks.isEmpty || !daySpans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel("Browser")
                    Spacer()
                    Text("\(fmtMins(chromeMinutes)) in Chrome")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    browserStat("\(blocks.count)", "blocked", color: red)
                    browserStat("\(blocks.filter(\.wasFocus).count)", "during focus", color: amber)
                    browserStat(focusHours >= 0.25 ? String(format: "%.1f", Double(blocks.filter(\.wasFocus).count) / focusHours) : "–",
                                "per focus hr", color: blue)
                    browserStat("\(blocks.filter(\.bypassed).count)", "bypassed", color: .secondary)
                }

                if !blocks.isEmpty {
                    let byLabel = Dictionary(grouping: blocks, by: \.label).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
                    HStack(spacing: 6) {
                        ForEach(byLabel, id: \.0) { label, n in
                            HStack(spacing: 4) {
                                Circle().fill(label == "Break" ? blue : categoryColor(label)).frame(width: 6, height: 6)
                                Text("\(label.isEmpty ? "—" : label) \(n)").font(.system(size: 10, design: .monospaced))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.08), in: Capsule())
                        }
                    }
                    domainCounts(BrowserStore.countByDomain(blocks))
                }

                HStack(alignment: .top, spacing: 14) {
                    if !byDomain.isEmpty {
                        domainBars("TIME BY SITE", byDomain, blocked: blockedSet)
                    }
                    if !focusByDomain.isEmpty {
                        domainBars("DURING FOCUS", focusByDomain, blocked: blockedSet)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        }
    }

    private func browserStat(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func domainCounts(_ counts: [(domain: String, count: Int)]) -> some View {
        VStack(spacing: 3) {
            ForEach(counts.prefix(5), id: \.domain) { entry in
                HStack {
                    Image(systemName: "hand.raised.fill").font(.system(size: 8)).foregroundStyle(red.opacity(0.8))
                    Text(entry.domain).font(.system(size: 11))
                    Spacer()
                    Text("\(entry.count)×").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func domainBars(_ title: String, _ rows: [(domain: String, seconds: TimeInterval)], blocked: Set<String>) -> some View {
        let top = Array(rows.prefix(6))
        let maxSec = top.first?.seconds ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
            ForEach(top, id: \.domain) { row in
                let isBlocked = blocked.contains { row.domain == $0 || row.domain.hasSuffix("." + $0) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.domain).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        Text(fmtMins(row.seconds / 60)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill((isBlocked ? red : blue).opacity(0.7))
                            .frame(width: max(2, geo.size.width * CGFloat(row.seconds / maxSec)))
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stat cards

    private var statCards: some View {
        HStack(spacing: 8) {
            dashCard(value: fmtMins(sessionStore.todayWorkMinutes), label: "Today's Focus", icon: "timer", color: red)
            if settings.dailyGoal > 0 {
                let pct = min(1.0, sessionStore.todayWorkMinutes / 60.0 / Double(settings.dailyGoal))
                let met = pct >= 1.0
                dashCard(
                    value: String(format: "%.0f%%", pct * 100),
                    label: "of \(settings.dailyGoal)h goal",
                    icon: met ? "checkmark.seal.fill" : "target",
                    color: met ? green : blue
                )
            } else {
                dashCard(value: fmtMins(sessionStore.todayBreakMinutes), label: "On Break", icon: "cup.and.saucer.fill", color: blue)
            }
            dashCard(value: "\(sessionStore.currentStreak)d", label: "Streak", icon: "flame.fill", color: .orange)
            dashCard(value: fmtHours(sessionStore.totalWorkHours), label: "Total Hours", icon: "clock.fill", color: blue)
        }
    }

    // MARK: - Problem progress

    private var problemProgressSection: some View {
        let cal = Calendar.current
        let hwTodayCount = homeworkStore.items.filter { cal.isDateInToday($0.date) }.count
        let hwGoal = settings.homeworkDailyGoal
        let hwPct: Double = hwGoal > 0 ? min(1, Double(hwTodayCount) / Double(hwGoal)) : 0
        let purple = Color(red: 0.62, green: 0.45, blue: 0.92)

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Problem progress")

            ForEach(ProblemDomain.allCases, id: \.self) { domain in
                let count = problemStore.count(for: domain)
                let goal  = domain == .quant ? settings.quantGoal : settings.sweGoal
                let pct: Double = goal > 0 ? min(1, Double(count) / Double(goal)) : 0
                let col: Color  = domain == .quant ? blue : green

                HStack(spacing: 8) {
                    Text(domain.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(col)
                        .frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(col.opacity(0.1))
                            if goal > 0 {
                                Capsule().fill(col.opacity(0.85))
                                    .frame(width: g.size.width * CGFloat(pct))
                                    .animation(.spring(response: 0.5), value: pct)
                            }
                        }
                    }
                    .frame(height: 6)
                    Text(goal > 0 ? "\(count)/\(goal)" : "\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Text("Homework")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(purple)
                    .frame(width: 64, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(purple.opacity(0.1))
                        if hwGoal > 0 {
                            Capsule().fill(purple.opacity(0.85))
                                .frame(width: g.size.width * CGFloat(hwPct))
                                .animation(.spring(response: 0.5), value: hwPct)
                        }
                    }
                }
                .frame(height: 6)
                Text(hwGoal > 0 ? "\(hwTodayCount)/\(hwGoal)" : "\(hwTodayCount)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }

            HStack(spacing: 0) {
                ForEach(problemStore.countByDifficulty(), id: \.difficulty) { item in
                    VStack(spacing: 1) {
                        Text("\(item.count)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(item.difficulty.color)
                        Text(item.difficulty.rawValue)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Divider().frame(height: 28)
                let rate = problemStore.cleanSolveRate
                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", rate * 100))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(rate >= 0.8 ? .green : rate >= 0.5 ? amber : .red)
                    Text("clean")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 28)
                VStack(spacing: 1) {
                    Text("\(problemStore.problemStreak)d")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Text("streak")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - 14-day chart

    private var weeklySection: some View {
        let summaries = sessionStore.dailySummaries(last: 14)
        let maxMins = max(1, summaries.map { $0.totalWorkMinutes }.max() ?? 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Last 14 days")
                Spacer()
                Text(fmtMins(sessionStore.last7DaysMinutes) + " this week")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(summaries, id: \.id) { day in
                    let isToday = Calendar.current.isDateInToday(day.date)
                    VStack(spacing: 2) {
                        if day.totalWorkMinutes > 0 {
                            Text(shortMins(day.totalWorkMinutes))
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(" ").font(.system(size: 7))
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.totalWorkMinutes > 0
                                  ? red.opacity(isToday ? 1.0 : 0.55)
                                  : Color.secondary.opacity(0.1))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(4, CGFloat(day.totalWorkMinutes / maxMins) * 50))
                        Text(weekdayLetter(day.date))
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(isToday ? red : Color.secondary.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 68)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - Focus split

    private var focusSplitSection: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6,
            to: Calendar.current.startOfDay(for: Date()))!
        let split = sessionStore.minutesByTag(since: start)
        let total = split.reduce(0.0) { $0 + $1.minutes }

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Focus split, last 7 days")
            if total == 0 {
                Text("No tagged sessions this week.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.08))
                        HStack(spacing: 0) {
                            ForEach(split, id: \.tag) { entry in
                                Rectangle()
                                    .fill(tagColor(entry.tag))
                                    .frame(width: geo.size.width * CGFloat(entry.minutes / total))
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 10)

                VStack(spacing: 4) {
                    ForEach(split, id: \.tag) { entry in
                        HStack(spacing: 6) {
                            Circle().fill(tagColor(entry.tag)).frame(width: 6, height: 6)
                            Text(entry.tag).font(.system(size: 11))
                            Spacer()
                            Text(fmtMins(entry.minutes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("\(Int(entry.minutes / total * 100))%")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - Insights

    private var insightsSection: some View {
        let delta = sessionStore.last7DaysMinutes - sessionStore.prior7DaysMinutes
        let hasPrior = sessionStore.prior7DaysMinutes > 0

        let tally7 = dayStore.commitmentTally(lastDays: 7)
        let committedDays7 = tally7.fulfilled + tally7.missed + tally7.unreviewed
        let streak = dayStore.commitmentStreak

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Insights")
            VStack(spacing: 6) {
                let consistency = sessionStore.consistencyScore(days: 14)
                iRow("Consistency (14d)", "\(Int(consistency * 100))%",
                     color: consistency >= 0.8 ? .green : consistency >= 0.5 ? .orange : .red)
                if committedDays7 > 0 {
                    iRow("Promises kept (7d)",
                         "\(tally7.fulfilled)/\(committedDays7)",
                         color: tally7.fulfilled == committedDays7 ? .green :
                                tally7.fulfilled * 2 >= committedDays7 ? .orange : .red)
                    iRow("Commitment streak", "\(streak)d",
                         color: streak >= 3 ? .green : .primary)
                }
                iRow("Avg session",  fmtMins(sessionStore.averageSessionMinutes(last: 20)))
                iRow("Best day",     fmtMins(sessionStore.bestDayMinutes))
                iRow("Best week",    fmtHours(sessionStore.bestWeekMinutes / 60.0))
                iRow("Best streak",  "\(sessionStore.bestStreak)d")
                if hasPrior {
                    iRow("vs last week",
                         (delta >= 0 ? "+" : "") + fmtMins(delta),
                         color: delta >= 0 ? .green : .red)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Commitment history

    private var commitmentHistorySection: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let committed = dayStore.committedDays
        let reviewed = committed.filter { $0.commitmentFulfilled != nil }
        let kept = reviewed.filter { $0.commitmentFulfilled == true }
        let cutoff30 = cal.date(byAdding: .day, value: -29, to: today)!
        let reviewed30 = reviewed.filter { $0.calendarDay >= cutoff30 }
        let kept30 = reviewed30.filter { $0.commitmentFulfilled == true }

        func focusHours(_ days: [DayRecord]) -> Double? {
            guard !days.isEmpty else { return nil }
            let total = days.reduce(0.0) { acc, r in
                acc + sessionStore.workMinutes(since: r.calendarDay,
                                               until: cal.date(byAdding: .day, value: 1, to: r.calendarDay)!)
            }
            return total / Double(days.count) / 60
        }
        let keptHours = focusHours(kept)
        let missedHours = focusHours(reviewed.filter { $0.commitmentFulfilled == false })

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Commitments")
                Spacer()
                if !reviewed.isEmpty {
                    Text("\(kept.count)/\(reviewed.count) kept all-time")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            if committed.isEmpty {
                Text("Write a commitment when you start your day; check in at night to build a record.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    commitmentStat("30-day",
                                   reviewed30.isEmpty ? "—" : "\(Int((Double(kept30.count) / Double(reviewed30.count) * 100).rounded()))%",
                                   sub: "\(kept30.count)/\(reviewed30.count) kept")
                    commitmentStat("Streak", "\(dayStore.commitmentStreak)d", sub: "best \(dayStore.bestCommitmentStreak)d")
                    commitmentStat("Focus when kept", keptHours.map { fmtHours($0) } ?? "—",
                                   sub: missedHours.map { "vs \(fmtHours($0)) missed" } ?? "avg per day")
                }

                commitmentStrip(from: cutoff30, days: 30)

                VStack(spacing: 4) {
                    ForEach(committed.prefix(7)) { rec in
                        commitmentHistoryRow(rec)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func commitmentStat(_ label: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(sub)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitmentStrip(from start: Date, days: Int) -> some View {
        let cal = Calendar.current
        return HStack(spacing: 3) {
            ForEach(0..<days, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: start)!
                let rec = dayStore.record(for: day)
                let hasText = rec?.commitmentText?.isEmpty == false
                let color: Color = !hasText ? Color.secondary.opacity(0.08)
                    : rec?.commitmentFulfilled == true ? green
                    : rec?.commitmentFulfilled == false ? red
                    : Color.orange.opacity(0.5)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .help(stripHelp(day: day, rec: rec))
                    .onTapGesture { selectedDay = day }
            }
        }
    }

    private func stripHelp(day: Date, rec: DayRecord?) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        guard let text = rec?.commitmentText, !text.isEmpty else { return "\(f.string(from: day)) — no commitment" }
        let outcome = rec?.commitmentFulfilled.map { $0 ? "Kept" : "Missed" } ?? "Not reviewed"
        return "\(f.string(from: day)) — \(outcome)\n\(text)"
    }

    private func commitmentHistoryRow(_ rec: DayRecord) -> some View {
        let f = DateFormatter(); f.dateFormat = "EEE d"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(f.string(from: rec.calendarDay))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .leading)
            Text(rec.commitmentText ?? "")
                .font(.system(size: 11))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch rec.commitmentFulfilled {
            case .some(true):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(green).font(.system(size: 11))
            case .some(false):
                Image(systemName: "xmark.seal.fill").foregroundStyle(red).font(.system(size: 11))
            case .none:
                Button { reviewTargetForDashboard = rec } label: {
                    Text(Calendar.current.isDateInToday(rec.calendarDay) ? "Check in" : "Review")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = rec.calendarDay }
    }

    // MARK: - Weak areas

    private var weakAreasSection: some View {
        let weak = problemStore.weakestCategories(limit: 4)

        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Weak areas")
            if weak.isEmpty {
                Text("Log 2+ problems per category to see weak spots.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 5) {
                    ForEach(weak, id: \.category) { item in
                        HStack(spacing: 6) {
                            Circle().fill(scoreColor(item.avgScore)).frame(width: 6, height: 6)
                            Text(item.category)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Lifetime

    private var lifetimeSection: some View {
        HStack(spacing: 0) {
            lStat("\(sessionStore.totalWorkSessions)", "Sessions")
            lStat(fmtHours(sessionStore.totalWorkHours), "Hours")
            lStat("\(problemStore.totalCount)", "Problems")
            lStat("\(sessionStore.bestStreak)d", "Best Streak",
                  icon: "trophy.fill", iconColor: Color(red: 1, green: 0.75, blue: 0.2))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: - Helpers

    private func dashCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.07))
        .cornerRadius(10)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .semibold))
    }

    private func iRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(color)
        }
    }

    private func lStat(_ value: String, _ label: String, icon: String? = nil, iconColor: Color = .primary) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(iconColor) }
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func tagColor(_ tag: String) -> Color { categoryColor(tag) }

    private func scoreColor(_ score: Double) -> Color {
        score < 0.7 ? .red : score < 1.4 ? amber : green
    }

    private var todayDateString: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: Date())
    }

    private func clockStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"; return f.string(from: d)
    }

    private func weekdayLetter(_ date: Date) -> String {
        let idx = Calendar.current.component(.weekday, from: date) - 1
        return ["S","M","T","W","T","F","S"][idx]
    }

    private func shortMins(_ m: Double) -> String {
        let h = Int(m) / 60
        return h > 0 ? "\(h)h" : "\(Int(m))m"
    }
}

private struct DashboardDeferredSection<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View { content() }
}

private struct DashboardFloatingTimer: View {
    @ObservedObject var timer: TimerManager

    var body: some View {
        if timer.isActive { NowPlayingBar(timer: timer) }
    }
}

private struct DashboardFocusSummary: View {
    let day: Date
    let sessions: [WorkSession]
    let goalHours: Int
    let problemCount: Int
    let accent: Color

    var body: some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let focus = sessions.filter(\.isFocus).map { session in
            (label: session.label ?? "Focus",
             minutes: max(0, min(end, session.startTime.addingTimeInterval(session.durationMinutes * 60))
                .timeIntervalSince(max(day, session.startTime))) / 60)
        }
        let minutes = focus.reduce(0) { $0 + $1.minutes }
        let goal = Double(goalHours) * 60
        let byCategory = Dictionary(grouping: focus.filter { $0.minutes > 0 }, by: \.label)
            .map { (label: $0.key, minutes: $0.value.reduce(0) { $0 + $1.minutes }) }
            .sorted { $0.minutes > $1.minutes }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(fmtMins(minutes))
                    .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                Text("of focus").font(.system(size: 15)).foregroundStyle(Color.secondaryText)
                Spacer(minLength: 12)
                if problemCount > 0 {
                    Label("\(problemCount) \(problemCount == 1 ? "problem" : "problems")", systemImage: "checkmark.circle")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
            }
            if goal > 0 {
                HStack(spacing: 12) {
                    GeometryReader { geometry in
                        Capsule().fill(accent.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(minutes >= goal ? Color.good : accent)
                                    .frame(width: geometry.size.width * min(1, minutes / goal))
                            }
                    }
                    .frame(maxWidth: 160).frame(height: 4)
                    Text(minutes >= goal ? "\(goalHours)h goal met" : "\(fmtMins(goal - minutes)) to your \(goalHours)h goal")
                        .font(.system(size: 13)).foregroundStyle(minutes >= goal ? Color.good : .secondaryText)
                }
            }
            if !byCategory.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(byCategory, id: \.label) { item in
                            HStack(spacing: 6) {
                                Circle().fill(categoryColor(item.label)).frame(width: 6, height: 6)
                                Text(item.label).font(.system(size: 13, weight: .medium))
                                Text(fmtMins(item.minutes)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pulsing dot for in-progress events

private struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(on ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Today's log event row

private struct EventRow: View {
    let event: DayEvent
    let onTap: () -> Void

    @State private var isHovered = false
    private let red  = Color(red: 0.96, green: 0.36, blue: 0.36)
    private let blue = Color(red: 0.27, green: 0.62, blue: 0.83)

    private var isEditable: Bool {
        switch event.kind {
        case .focus, .problem, .breakSession: return true
        case .inProgressFocus, .inProgressBreak: return false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(timeStr)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .padding(.trailing, 10)

            switch event.kind {
            case .focus(let s):       focusRow(s)
            case .breakSession(let s): breakRow(s)
            case .problem(let p):     problemRow(p)
            case .inProgressFocus(_, let mins, let label): inProgressRow(mins: mins, label: label)
            case .inProgressBreak(_, let mins): inProgressBreakRow(mins: mins)
            }

            if isHovered && isEditable {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered && isEditable ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { if isEditable { onTap() } }
    }

    private var timeStr: String {
        event.time.formatted(date: .omitted, time: .shortened)
    }

    private func inProgressRow(mins: Double, label: String?) -> some View {
        HStack(spacing: 8) {
            let c = categoryColor(label ?? "")
            RoundedRectangle(cornerRadius: 2)
                .fill(c)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label.flatMap { $0.isEmpty ? nil : $0 } ?? "Focus")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    PulsingDot(color: c)
                }
                Text(fmtMins(mins) + " so far")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func inProgressBreakRow(mins: Double) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(blue)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Break")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    PulsingDot(color: blue)
                }
                Text(fmtMins(mins) + " so far")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 10))
                .foregroundStyle(blue.opacity(0.4))
        }
    }

    private func focusRow(_ s: WorkSession) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(categoryColor(s.label ?? ""))
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Focus")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(fmtMins(s.durationMinutes))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func breakRow(_ s: WorkSession) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(blue.opacity(0.5))
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Break")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let kinds = s.breakKinds, !kinds.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(kinds) { k in
                                Image(systemName: k.icon)
                                    .font(.system(size: 9))
                                    .foregroundStyle(blue.opacity(0.85))
                            }
                        }
                    }
                }
                Text(breakSubtitle(s))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 10))
                .foregroundStyle(blue.opacity(0.4))
        }
    }

    private func breakSubtitle(_ s: WorkSession) -> String {
        let mins = fmtMins(s.durationMinutes)
        if let kinds = s.breakKinds, !kinds.isEmpty {
            return mins + " · " + kinds.map(\.displayName).joined(separator: ", ")
        }
        return mins
    }

    private func problemRow(_ p: ProblemEntry) -> some View {
        HStack(spacing: 8) {
            Circle().fill(p.confidence.color).frame(width: 7, height: 7)
            Text(p.title.isEmpty ? (p.categories.first ?? "Problem") : p.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Text(String(p.difficulty.rawValue.prefix(1)))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(p.difficulty.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(p.difficulty.color.opacity(0.1))
                .cornerRadius(3)
        }
    }
}

// MARK: - Edit sheet

private struct EventEditSheet: View {
    let event: DayEvent
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var problemStore: ProblemStore
    @Environment(\.dismiss) private var dismiss

    private let red = Color(red: 0.96, green: 0.36, blue: 0.36)

    @State private var selectedLabel = ""
    @State private var selectedConfidence: Confidence = .solid
    @State private var selectedDifficulty: ProblemDifficulty = .medium
    @State private var selectedBreakKinds: Set<BreakKind> = []

    private let blue = Color(red: 0.27, green: 0.62, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit Entry")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                switch event.kind {
                case .focus(let s):        sessionFields(s)
                case .problem(let p):      problemFields(p)
                case .breakSession(let s): breakFields(s)
                case .inProgressFocus:     EmptyView()
                case .inProgressBreak:     EmptyView()
                }
            }
            .padding(16)

            Spacer(minLength: 0)
        }
        .frame(width: 280)
        .onAppear {
            switch event.kind {
            case .focus(let s):
                selectedLabel = s.label ?? ""
            case .problem(let p):
                selectedConfidence = p.confidence
                selectedDifficulty = p.difficulty
            case .breakSession(let s):
                selectedBreakKinds = Set(s.breakKinds ?? [])
            case .inProgressFocus, .inProgressBreak:
                break
            }
        }
    }

    @ViewBuilder
    private func sessionFields(_ s: WorkSession) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "timer").font(.system(size: 11)).foregroundStyle(red)
            Text(clockStr(s.startTime) + " · " + fmtMins(s.durationMinutes))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 7) {
            sheetLabel("CATEGORY")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    let noneSelected = selectedLabel.isEmpty
                    Button("None") { selectedLabel = "" }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(noneSelected ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.07))
                        .foregroundStyle(noneSelected ? .primary : .secondary)
                        .cornerRadius(6).buttonStyle(.plain)
                    ForEach(settings.tags, id: \.self) { tag in
                        let sel = selectedLabel == tag
                        Button(tag) { selectedLabel = sel ? "" : tag }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sel ? red.opacity(0.15) : Color.secondary.opacity(0.07))
                            .foregroundStyle(sel ? red : .secondary)
                            .cornerRadius(6).buttonStyle(.plain)
                    }
                }
            }
        }

        saveButton {
            sessionStore.updateLabel(id: s.id, label: selectedLabel.isEmpty ? nil : selectedLabel)
        }
    }

    @ViewBuilder
    private func breakFields(_ s: WorkSession) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cup.and.saucer").font(.system(size: 11)).foregroundStyle(blue)
            Text(clockStr(s.startTime) + " · " + fmtMins(s.durationMinutes))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 7) {
            sheetLabel("TYPE")
            HStack(spacing: 6) {
                ForEach(BreakKind.allCases) { kind in
                    let sel = selectedBreakKinds.contains(kind)
                    Button {
                        if sel { selectedBreakKinds.remove(kind) }
                        else   { selectedBreakKinds.insert(kind) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.icon).font(.system(size: 10))
                            Text(kind.displayName).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(sel ? blue.opacity(0.15) : Color.secondary.opacity(0.07))
                    .foregroundStyle(sel ? blue : .secondary)
                    .cornerRadius(6).buttonStyle(.plain)
                }
            }
        }

        saveButton {
            let ordered = BreakKind.allCases.filter { selectedBreakKinds.contains($0) }
            sessionStore.updateBreakKinds(id: s.id, kinds: ordered)
        }
    }

    @ViewBuilder
    private func problemFields(_ p: ProblemEntry) -> some View {
        if !p.title.isEmpty {
            Text(p.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }

        VStack(alignment: .leading, spacing: 7) {
            sheetLabel("CONFIDENCE")
            HStack(spacing: 6) {
                ForEach(Confidence.allCases, id: \.self) { conf in
                    let sel = selectedConfidence == conf
                    Button(conf.rawValue) { selectedConfidence = conf }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(sel ? conf.color.opacity(0.15) : Color.secondary.opacity(0.07))
                        .foregroundStyle(sel ? conf.color : .secondary)
                        .cornerRadius(6).buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: 7) {
            sheetLabel("DIFFICULTY")
            HStack(spacing: 6) {
                ForEach(ProblemDifficulty.allCases, id: \.self) { diff in
                    let sel = selectedDifficulty == diff
                    Button(diff.rawValue) { selectedDifficulty = diff }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(sel ? diff.color.opacity(0.15) : Color.secondary.opacity(0.07))
                        .foregroundStyle(sel ? diff.color : .secondary)
                        .cornerRadius(6).buttonStyle(.plain)
                }
            }
        }

        saveButton {
            var updated = p
            updated.confidence = selectedConfidence
            updated.difficulty = selectedDifficulty
            problemStore.update(updated)
        }
    }

    private func saveButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Text("Save")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(red)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func sheetLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .semibold))
    }

    private func clockStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"; return f.string(from: d)
    }
}

// MARK: - Day timeline canvas

private struct DayTimelineCanvas: View {
    let day: Date
    let focus: [WorkSession]
    let breaks: [WorkSession]
    let livefocus: WorkSession?
    let liveBreak: WorkSession?
    let red: Color
    let blue: Color
    let tags: [String]
    let screen: [ScreenSpan]
    let onFill: (Date, Date, String?) -> Void

    @State private var fillingGap: Gap?
    private let screenLaneWidth: CGFloat = 8

    private struct ScreenBar {
        let start: Date
        let end: Date
        let category: String?
        let summaries: [String]
    }

    /// Adjacent spans with the same label merged, so the lane stays light.
    private var screenBars: [ScreenBar] {
        var out: [ScreenBar] = []
        for s in screen.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.category == s.category, s.start.timeIntervalSince(last.end) < 120 {
                let sums = last.summaries.contains(s.summary) ? last.summaries : last.summaries + [s.summary]
                out[out.count - 1] = ScreenBar(start: last.start, end: s.end, category: last.category, summaries: sums)
            } else {
                out.append(ScreenBar(start: s.start, end: s.end, category: s.category, summaries: [s.summary]))
            }
        }
        return out
    }

    struct Gap: Identifiable, Equatable {
        let start: Date
        let end: Date
        var id: Date { start }
    }

    private struct Block {
        let start: Date
        let end: Date
        let label: String
        let subtitle: String?
        let color: Color
        let isLive: Bool
    }

    private struct LaidOut {
        let block: Block
        let lane: Int
        let totalLanes: Int
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for s in focus {
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            out.append(Block(
                start: s.startTime, end: end,
                label: s.label?.isEmpty == false ? s.label! : "Focus",
                subtitle: fmtDuration(s.durationMinutes),
                color: s.label?.isEmpty == false ? categoryColor(s.label!) : red, isLive: false
            ))
        }
        for s in breaks {
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            let kindStr = (s.breakKinds ?? []).map(\.displayName).joined(separator: ", ")
            out.append(Block(
                start: s.startTime, end: end,
                label: kindStr.isEmpty ? "Break" : kindStr,
                subtitle: fmtDuration(s.durationMinutes),
                color: blue, isLive: false
            ))
        }
        if let live = livefocus {
            let end = live.startTime.addingTimeInterval(live.durationMinutes * 60)
            out.append(Block(
                start: live.startTime, end: end,
                label: live.label?.isEmpty == false ? live.label! : "Focus",
                subtitle: fmtDuration(live.durationMinutes) + " · live",
                color: live.label?.isEmpty == false ? categoryColor(live.label!) : red, isLive: true
            ))
        }
        if let live = liveBreak {
            let end = live.startTime.addingTimeInterval(live.durationMinutes * 60)
            out.append(Block(
                start: live.startTime, end: end,
                label: "Break",
                subtitle: fmtDuration(live.durationMinutes) + " · live",
                color: blue, isLive: true
            ))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Standard calendar-style lane assignment: overlapping blocks get
    /// horizontal columns. A block's `totalLanes` is the column count for
    /// its conflict cluster (a maximal chain of transitively-overlapping
    /// blocks). Renders side-by-side instead of Z-stacked.
    private var laidOut: [LaidOut] {
        let sorted = blocks
        var assignments: [(block: Block, lane: Int)] = []
        var laneEnds: [Date] = []

        for b in sorted {
            var lane = -1
            for (i, e) in laneEnds.enumerated() where e <= b.start {
                lane = i; break
            }
            if lane == -1 {
                lane = laneEnds.count
                laneEnds.append(b.end)
            } else {
                laneEnds[lane] = b.end
            }
            assignments.append((b, lane))
        }

        var result: [LaidOut] = []
        var cluster: [(Block, Int)] = []
        var clusterEnd: Date? = nil
        let flush: ([(Block, Int)]) -> Void = { items in
            let total = (items.map(\.1).max() ?? 0) + 1
            for (blk, lane) in items {
                result.append(LaidOut(block: blk, lane: lane, totalLanes: total))
            }
        }
        for item in assignments {
            if let ce = clusterEnd, item.block.start < ce {
                cluster.append(item)
                clusterEnd = max(ce, item.block.end)
            } else {
                if !cluster.isEmpty { flush(cluster) }
                cluster = [item]
                clusterEnd = item.block.end
            }
        }
        if !cluster.isEmpty { flush(cluster) }
        return result
    }

    private var hourRange: (start: Int, end: Int) { (0, 24) }

    /// Untracked stretches of 5+ minutes between midnight and now (or the
    /// end of a past day).
    private var gaps: [Gap] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = min(cal.date(byAdding: .day, value: 1, to: dayStart)!, Date())
        var out: [Gap] = []
        var cursor = dayStart
        for b in blocks where b.end > cursor {
            if b.start.timeIntervalSince(cursor) >= 300 { out.append(Gap(start: cursor, end: min(b.start, dayEnd))) }
            cursor = max(cursor, b.end)
        }
        if dayEnd.timeIntervalSince(cursor) >= 300 { out.append(Gap(start: cursor, end: dayEnd)) }
        return out.filter { $0.end > $0.start }
    }

    private let rowHeight: CGFloat = 16
    private let leftCol: CGFloat = 38

    var body: some View {
        let range = hourRange
        let totalHours = range.end - range.start
        let height = CGFloat(totalHours) * rowHeight

        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(range.start..<range.end, id: \.self) { h in
                    Text(hourLabel(h))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: leftCol, height: rowHeight, alignment: .trailing)
                }
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<totalHours, id: \.self) { i in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.06))
                            .frame(height: 0.5)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .frame(height: height)
                .background(Color.secondary.opacity(0.03))
                .cornerRadius(4)

                GeometryReader { geo in
                    let lane = screen.isEmpty ? 0 : screenLaneWidth + 4
                    let width = geo.size.width - lane
                    ForEach(gaps) { gap in
                        gapView(gap, range: range, totalHeight: height, width: width)
                    }
                    ForEach(Array(laidOut.enumerated()), id: \.offset) { _, item in
                        block(item, range: range, totalHeight: height, width: width)
                    }
                    ForEach(Array(screenBars.enumerated()), id: \.offset) { _, bar in
                        screenBar(bar, totalHeight: height, x: geo.size.width - screenLaneWidth)
                    }
                }
                .frame(height: height)
            }
        }
    }

    private func block(_ item: LaidOut, range: (start: Int, end: Int), totalHeight: CGFloat, width: CGFloat) -> some View {
        let b = item.block
        let totalSeconds = Double(range.end - range.start) * 3600.0
        let cal = Calendar.current
        let rangeStartDate = cal.date(bySettingHour: range.start, minute: 0, second: 0, of: day)!
        let startOffset = b.start.timeIntervalSince(rangeStartDate)
        let duration = b.end.timeIntervalSince(b.start)
        let y = max(0, CGFloat(startOffset / totalSeconds) * totalHeight)
        let h = max(8, CGFloat(duration / totalSeconds) * totalHeight)

        // Lane-based column. Leaves a small gutter between concurrent blocks.
        let gutter: CGFloat = item.totalLanes > 1 ? 2 : 0
        let laneWidth = (width - gutter * CGFloat(item.totalLanes - 1)) / CGFloat(item.totalLanes)
        let x = CGFloat(item.lane) * (laneWidth + gutter)

        return RoundedRectangle(cornerRadius: 4)
            .fill(b.color.opacity(b.isLive ? 0.85 : 0.75))
            .overlay(
                HStack(spacing: 4) {
                    Text(b.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let sub = b.subtitle, h >= 18, item.totalLanes <= 2 {
                        Text("· \(sub)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 5)
            )
            .frame(width: laneWidth, height: h)
            .offset(x: x, y: y)
    }

    private func screenBar(_ bar: ScreenBar, totalHeight: CGFloat, x: CGFloat) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let y = CGFloat(bar.start.timeIntervalSince(dayStart) / 86400) * totalHeight
        let h = max(2, CGFloat(bar.end.timeIntervalSince(bar.start) / 86400) * totalHeight)
        let when = "\(bar.start.formatted(date: .omitted, time: .shortened))–\(bar.end.formatted(date: .omitted, time: .shortened))"
        return RoundedRectangle(cornerRadius: 2)
            .fill(bar.category.map(categoryColor) ?? Color.secondary.opacity(0.35))
            .frame(width: screenLaneWidth, height: h)
            .offset(x: x, y: y)
            .help("Screen \(when) · \(bar.category ?? "Unlabeled")\n" + bar.summaries.prefix(4).joined(separator: "\n"))
    }

    private func gapView(_ gap: Gap, range: (start: Int, end: Int), totalHeight: CGFloat, width: CGFloat) -> some View {
        let totalSeconds = Double(range.end - range.start) * 3600.0
        let y = CGFloat(gap.start.timeIntervalSince(Calendar.current.startOfDay(for: day)) / totalSeconds) * totalHeight
        let h = max(6, CGFloat(gap.end.timeIntervalSince(gap.start) / totalSeconds) * totalHeight)
        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(fillingGap == gap ? 0.12 : 0.001)))
            .overlay(alignment: .leading) {
                if h >= 12 {
                    Text("Untracked · \(fmtDuration(gap.end.timeIntervalSince(gap.start) / 60))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                }
            }
            .frame(width: width, height: h)
            .contentShape(Rectangle())
            .onTapGesture { fillingGap = gap }
            .popover(isPresented: Binding(get: { fillingGap == gap }, set: { if !$0 { fillingGap = nil } })) {
                GapFillPopover(gap: gap, tags: tags) { start, end, label in
                    onFill(start, end, label)
                    fillingGap = nil
                }
            }
            .offset(y: y)
            .help("Click to log what you were doing")
    }

    private func hourLabel(_ h: Int) -> String {
        let mod = h % 12 == 0 ? 12 : h % 12
        let ampm = h < 12 ? "a" : "p"
        return "\(mod)\(ampm)"
    }

    private func fmtDuration(_ m: Double) -> String {
        let h = Int(m) / 60, mn = Int(m) % 60
        return h > 0 ? "\(h)h \(mn)m" : "\(Int(m))m"
    }
}

private struct GapFillPopover: View {
    let gap: DayTimelineCanvas.Gap
    let tags: [String]
    let onPick: (Date, Date, String?) -> Void

    @State private var start: Date
    @State private var end: Date

    init(gap: DayTimelineCanvas.Gap, tags: [String], onPick: @escaping (Date, Date, String?) -> Void) {
        self.gap = gap
        self.tags = tags
        self.onPick = onPick
        _start = State(initialValue: gap.start)
        _end = State(initialValue: gap.end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What were you doing?")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                DatePicker("", selection: $start, in: gap.start...end, displayedComponents: .hourAndMinute)
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: $end, in: start...gap.end, displayedComponents: .hourAndMinute)
            }
            .labelsHidden()
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in chip(tag, color: categoryColor(tag)) { onPick(start, end, tag) } }
                chip("Break", color: Color(red: 0.27, green: 0.62, blue: 0.83)) { onPick(start, end, nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func chip(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .buttonStyle(.plain)
            .disabled(end.timeIntervalSince(start) < 60)
    }
}

// MARK: - Day ring

/// The day as a 24-hour dial (DESIGN.md idea 4): what you tracked on the
/// outer ring, what the screen thought on the inner one, a hand at now.
/// Hover to scrub. Beside it, one big number per fact (idea 5).
struct DayRingSection: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var watcher: ScreenWatcher
    @ObservedObject var settings: AppSettings
    let day: Date
    let sessions: [WorkSession]

    @State private var scrub: Date?
    private let cal = Calendar.current
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: day)! }
    private var isToday: Bool { cal.isDateInToday(day) }

    private struct Arc { let start: Date, end: Date, label: String }

    private var tracked: [Arc] {
        sessions.compactMap { s in
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            guard e > day, s.startTime < dayEnd else { return nil }
            return Arc(start: max(day, s.startTime), end: min(dayEnd, e), label: s.type != .work ? "Break" : (s.label ?? "Focus"))
        }
    }

    /// Blocks under 3 min fold into their neighbour so the inner ring reads
    /// as stretches, not confetti (the Snapshots card has the detail).
    private var screen: [Arc] {
        var out: [Arc] = []
        for a in watcher.activities(from: day, to: dayEnd) {
            guard let c = a.category else { continue }
            if let l = out.last, l.label == c || a.minutes < 3, a.start.timeIntervalSince(l.end) < 300 {
                out[out.count - 1] = Arc(start: l.start, end: a.end, label: l.label)
            } else {
                out.append(Arc(start: a.start, end: a.end, label: c))
            }
        }
        return out
    }

    /// Focus minutes on `d` before `cutoff` seconds into the day.
    private func focus(on d: Date, before cutoff: TimeInterval) -> Double {
        let start = cal.startOfDay(for: d), stop = start.addingTimeInterval(cutoff)
        return store.sessions.filter(\.isFocus).reduce(0) { sum, s in
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            return sum + max(0, min(e, stop).timeIntervalSince(max(s.startTime, start))) / 60
        }
    }

    var body: some View {
        let arcs = tracked, guesses = screen
        let cutoff = isToday ? Date().timeIntervalSince(day) : 86400
        let today = sessions.filter { $0.isFocus }.reduce(0.0) { sum, s in
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            return sum + max(0, min(e, dayEnd).timeIntervalSince(max(s.startTime, day))) / 60
        }
        let past = (1...6).compactMap { cal.date(byAdding: .day, value: -7 * $0, to: day) }
            .filter { d in store.sessions.contains { cal.isDate($0.startTime, inSameDayAs: d) } }
        let usual = past.isEmpty ? nil : past.map { focus(on: $0, before: cutoff) }.reduce(0, +) / Double(past.count)
        let weekday = day.formatted(.dateTime.weekday(.wide))
        HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 8) {
                ring(arcs, guesses)
                    .frame(width: 220, height: 220)
                HStack(spacing: 12) {
                    Label("Outer: you", systemImage: "circle")
                    Label("Inner: screen", systemImage: "circle.dotted")
                }
                .labelStyle(.titleOnly)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                heroNumber(fmt(today), "focus",
                          usual.map { u in
                              let d = today - u
                              guard abs(d) >= 5 else { return "about your usual \(weekday)\(isToday ? " by now" : "")" }
                              return "\(fmt(abs(d))) \(d > 0 ? "more" : "less") than your usual \(weekday)\(isToday ? " by now" : "")"
                          } ?? "no other \(weekday)s yet",
                          goal: settings.dailyGoal > 0 ? {
                              let goal = Double(settings.dailyGoal) * 60
                              return today >= goal ? "\(settings.dailyGoal)h goal met, \(fmt(today - goal)) to spare"
                                  : "\(fmt(goal - today)) to your \(settings.dailyGoal)h goal"
                          }() : nil,
                          met: settings.dailyGoal > 0 && today / 60 >= Double(settings.dailyGoal))
                let streak = store.currentStreak
                if isToday, streak > 0 {
                    bigNumber("\(streak)", "day streak", "\(fmt(store.totalWorkHours * 60)) of focus all-time", tint: .primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func heroNumber(_ value: String, _ unit: String, _ line: String, goal: String?, met: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            }
            if let goal {
                Label(goal, systemImage: met ? "checkmark.circle.fill" : "target")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(met ? Color.good : .secondary)
            }
            Text(line).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func bigNumber(_ value: String, _ unit: String, _ line: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(tint)
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func agreement(_ arcs: [Arc], _ guesses: [Arc]) -> Double? {
        var total = 0.0, same = 0.0
        for g in guesses {
            for a in arcs {
                let o = min(g.end, a.end).timeIntervalSince(max(g.start, a.start))
                guard o > 0 else { continue }
                total += o
                if a.label == g.label { same += o }
            }
        }
        return total >= 600 ? same / total : nil
    }

    private func angle(_ d: Date) -> Angle {
        .degrees(d.timeIntervalSince(day) / 86400 * 360 - 90)
    }

    private func ring(_ arcs: [Arc], _ guesses: [Arc]) -> some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                Canvas { ctx, _ in
                    func band(_ list: [Arc], radius: CGFloat, width: CGFloat, alpha: Double) {
                        var track = Path()
                        track.addArc(center: c, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                        ctx.stroke(track, with: .color(.primary.opacity(0.07)), lineWidth: width)
                        for a in list {
                            var p = Path()
                            p.addArc(center: c, radius: radius, startAngle: angle(a.start), endAngle: angle(a.end), clockwise: false)
                            let col = a.label == "Break" ? TimerView.breakBlue.opacity(0.5) : categoryColor(a.label)
                            ctx.stroke(p, with: .color(col.opacity(alpha)), style: StrokeStyle(lineWidth: width, lineCap: .butt))
                        }
                    }
                    band(arcs, radius: size / 2 - 26, width: 16, alpha: 1)
                    band(guesses, radius: size / 2 - 46, width: 8, alpha: 0.8)
                    for h in stride(from: 0, to: 24, by: 3) {
                        let a = Angle.degrees(Double(h) / 24 * 360 - 90).radians
                        let r1 = size / 2 - 15, r2 = size / 2 - (h % 6 == 0 ? 19 : 17)
                        var t = Path()
                        t.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                        t.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
                        ctx.stroke(t, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    }
                    if let hand = scrub ?? (isToday ? Date() : nil) {
                        let a = angle(hand).radians
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * (size / 2 - 54), y: c.y + sin(a) * (size / 2 - 54)))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * (size / 2 - 16), y: c.y + sin(a) * (size / 2 - 16)))
                        ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                ForEach([(0, "12a"), (6, "6a"), (12, "12p"), (18, "6p")], id: \.0) { h, label in
                    let a = Angle.degrees(Double(h) / 24 * 360 - 90).radians
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                        .position(x: c.x + cos(a) * (size / 2 - 6), y: c.y + sin(a) * (size / 2 - 6))
                }
                center(arcs, guesses)
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    var a = atan2(p.y - c.y, p.x - c.x) + .pi / 2
                    if a < 0 { a += 2 * .pi }
                    scrub = day.addingTimeInterval(a / (2 * .pi) * 86400)
                case .ended: scrub = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day ring: tracked categories outside, screen guesses inside")
    }

    @ViewBuilder
    private func center(_ arcs: [Arc], _ guesses: [Arc]) -> some View {
        VStack(spacing: 2) {
            if let t = scrub {
                Text(t.formatted(date: .omitted, time: .shortened)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                let you = arcs.last { $0.start <= t && $0.end > t }?.label
                let it = guesses.last { $0.start <= t && $0.end > t }?.label
                Text("You: \(you ?? "nothing")").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Screen: \(it ?? "nothing")").font(.system(size: 12))
                    .foregroundStyle(it != nil && you != nil && it != you ? Color.orange : .secondary)
            } else {
                if isToday {
                    Text(Date().formatted(date: .omitted, time: .shortened)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    if let now = arcs.last(where: { $0.start <= Date() && $0.end >= Date().addingTimeInterval(-60) })?.label {
                        Text(now).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                } else {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).month().day())).font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    private func fmt(_ m: Double) -> String {
        durationText(minutes: m)
    }
}


// MARK: - Exams

/// Exams from your calendar with a countdown and the focus hours you've put
/// into that subject over the two weeks before (CLAUDE.md roadmap: exam radar).
struct ExamRadarSection: View {
    @ObservedObject var calendar = ClassCalendar.shared
    let sessions: [WorkSession]

    private func hours(_ category: String?, from: Date, to: Date) -> Double {
        sessions.filter { $0.isFocus && (category == nil || $0.label == category) }.reduce(0) { sum, s in
            let e = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            return sum + max(0, min(e, to).timeIntervalSince(max(s.startTime, from))) / 3600
        }
    }

    var body: some View {
        if !calendar.exams.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Exams", subtitle: "Coming up on your calendar, with how much of that subject you tracked this week")
                ForEach(calendar.exams.prefix(4)) { exam in
                    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                               to: Calendar.current.startOfDay(for: exam.date)).day ?? 0
                    let twoWeeks = hours(exam.category, from: exam.date.addingTimeInterval(-14 * 86400), to: min(Date(), exam.date))
                    let week = hours(exam.category, from: Date().addingTimeInterval(-7 * 86400), to: Date())
                    HStack(alignment: .center, spacing: 14) {
                        VStack(spacing: 0) {
                            Text(days <= 0 ? "Today" : "\(days)")
                                .font(.system(size: days <= 0 ? 15 : 22, weight: .semibold, design: .rounded).monospacedDigit())
                            if days > 0 { Text(days == 1 ? "day" : "days").font(.system(size: 11)).foregroundStyle(Color.secondaryText) }
                        }
                        .frame(width: 52)
                        .foregroundStyle(days <= 3 ? Color.orange : .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if let c = exam.category { Circle().fill(categoryColor(c)).frame(width: 8, height: 8) }
                                Text(exam.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            }
                            Text(exam.date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
                                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        }
                        Spacer()
                        if let c = exam.category {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(durationText(minutes: week * 60)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                                Text("\(c) on your timer this week").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                            }
                            .help("\(durationText(minutes: twoWeeks * 60)) of \(c) in the two weeks before it")
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        }
    }
}


// MARK: - Insights

/// When you work best (focus by hour of day and how often you drift then,
/// last 4 weeks) and a weekly letter written from it by the cloud coach (or Claude).
struct InsightsSection: View {
    @ObservedObject var watcher: ScreenWatcher
    let sessions: [WorkSession]
    @AppStorage("weeklyLetter") private var letterData = ""
    @State private var writing = false
    @State private var error = ""

    private let cal = Calendar.current

    private struct Hour { let hour: Int; let focus: Double; let drift: Double }

    private var hours: [Hour] {
        let from = cal.date(byAdding: .day, value: -28, to: cal.startOfDay(for: Date()))!
        var focus = [Double](repeating: 0, count: 24), drift = [Double](repeating: 0, count: 24)
        for s in sessions where s.isFocus && s.startTime >= from {
            var t = s.startTime
            let end = s.startTime.addingTimeInterval(s.durationMinutes * 60)
            while t < end {
                let h = cal.component(.hour, from: t)
                let next = min(end, cal.date(bySettingHour: h, minute: 0, second: 0, of: t)!.addingTimeInterval(3600))
                focus[h] += next.timeIntervalSince(t) / 60
                t = next
            }
        }
        for d in watcher.drifts(sessions: sessions, from: from, to: Date()) {
            drift[cal.component(.hour, from: d.start)] += d.minutes
        }
        return (0..<24).map { Hour(hour: $0, focus: focus[$0], drift: drift[$0]) }
    }

    /// The 3-hour window with the most focus, among those that drift less
    /// than your average.
    private func bestWindow(_ list: [Hour]) -> (start: Int, focus: Double, rate: Double)? {
        let total = list.reduce(0) { $0 + $1.focus }, drifts = list.reduce(0) { $0 + $1.drift }
        guard total >= 300 else { return nil }
        let average = drifts / (total / 60)
        let windows = (0..<22).map { h -> (Int, Double, Double) in
            let f = list[h..<h + 3].reduce(0) { $0 + $1.focus }, d = list[h..<h + 3].reduce(0) { $0 + $1.drift }
            return (h, f, f > 0 ? d / (f / 60) : 0)
        }
        return windows.filter { $0.1 > 60 && $0.2 <= average }.max { $0.1 < $1.1 }.map { ($0.0, $0.1, $0.2) }
    }

    private func clock(_ h: Int) -> String {
        cal.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour())
    }

    var body: some View {
        let list = hours
        let peak = max(list.map(\.focus).max() ?? 1, 1)
        let best = bestWindow(list)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("When you focus best", subtitle: "Focus by hour of day over the last 4 weeks. Orange marks time the screen showed you off-task.")
            if let best {
                Text("\(clock(best.start))–\(clock(best.start + 3)): the most focus with the fewest drifts over the last 4 weeks (\(String(format: "%.1f", best.rate)) min off-task per focus hour). Put the hardest work there.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(list, id: \.hour) { h in
                    let inBest = best.map { h.hour >= $0.start && h.hour < $0.start + 3 } ?? false
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(inBest ? Color.good : Color.primary.opacity(0.25))
                            .frame(height: max(2, 70 * h.focus / peak))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange.opacity(h.drift > 0 ? 0.8 : 0))
                            .frame(height: min(10, h.drift / 3))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(clock(h.hour)): \(durationText(minutes: h.focus)) focus, \(durationText(minutes: h.drift)) off-task (4 weeks)")
                }
            }
            .frame(height: 84, alignment: .bottom)
            HStack {
                Text(clock(0)); Spacer(); Text(clock(6)); Spacer(); Text(clock(12)); Spacer(); Text(clock(18)); Spacer(); Text(clock(23))
            }
            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
            Divider()
            letter
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private var weekKey: String {
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return start.formatted(.iso8601.year().month().day())
    }

    @ViewBuilder
    private var letter: some View {
        let parts = letterData.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0] == weekKey {
            VStack(alignment: .leading, spacing: 6) {
                Text("This week's letter").font(.system(size: 13, weight: .semibold))
                Text(parts[1]).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        } else if Coach.client != nil || RecallCoach.isConfigured {
            HStack {
                Button(writing ? "Writing…" : "Write this week's letter") { Task { await write() } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.indigo)
                    .disabled(writing)
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1) }
            }
        } else {
            Text("Turn on the cloud coach in Settings → Coach for a weekly letter written from your week.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
    }

    private func write() async {
        writing = true
        defer { writing = false }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var byCat: [String: Double] = [:]
        for s in sessions where s.startTime >= weekAgo && s.isFocus { byCat[s.label ?? "Focus", default: 0] += s.durationMinutes }
        let drifts = watcher.drifts(sessions: sessions, from: weekAgo, to: Date())
        let topics = watcher.activities(from: weekAgo, to: Date()).filter { $0.minutes >= 20 && $0.category != nil }
            .map { watcher.name(for: $0) }
        var seen = Set<String>()
        let uniqueTopics = topics.filter { seen.insert($0).inserted }.prefix(15)
        let best = bestWindow(hours)
        let facts = """
        Focus this week by category: \(byCat.sorted { $0.value > $1.value }.map { "\($0.key) \(durationText(minutes: $0.value))" }.joined(separator: ", "))
        Off-task during focus: \(drifts.count) drifts, \(durationText(minutes: drifts.reduce(0) { $0 + $1.minutes }))
        Best hours (4 weeks): \(best.map { "\(clock($0.start))–\(clock($0.start + 3))" } ?? "not enough data")
        What the screen saw them work on: \(uniqueTopics.joined(separator: "; "))
        """
        do {
            let text: String
            if let client = Coach.client {
                let days = CoachDayWorker.shared.recentRecords(days: 7).reversed().map { r in
                    "\(r.day): \(r.content.headline)" + r.content.study.map { " [\($0.course ?? $0.category): \($0.topics.joined(separator: ", "))\($0.shaky.isEmpty ? "" : "; shaky: " + $0.shaky.joined(separator: "; "))]" }.joined()
                }
                text = try await Self.coachLetter(client: client, facts: facts + "\nThe coach's day records:\n" + days.joined(separator: "\n"))
            } else {
                text = try await RecallCoach.weeklyLetter(facts)
            }
            letterData = weekKey + "\u{1F}" + text
            error = ""
        } catch {
            self.error = "Couldn't write it: \(CoachDayWorker.describe(error))"
        }
    }

    private static func coachLetter(client: XAIClient, facts: String) async throws -> String {
        let system = """
        Write a short weekly letter (150–250 words) to a Yale CS student preparing for quant and SWE interviews, \
        from their own tracking data. Plain, warm, specific; no headings, no bullet lists, no flattery. \
        Say what went well with numbers, the one pattern most worth changing (which course or goal got too little, \
        practice vs. reading, when they drift), and one concrete plan for next week. Address them as "you". \
        Use only the facts given; don't invent courses, exams or numbers.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["letter": ["type": "string"]], "required": ["letter"],
        ]
        let model = XAIClient.Model.strong
        let estimate = XAIClient.estimateUSD(model: model, text: system + facts, images: 0, maxOutputTokens: 2000,
                                             reasoningEffort: "low")
        let reply = try await Coach.budget.run(estimateUSD: estimate, model: model, purpose: "weekly-letter") {
            try await client.complete(model: model, system: system, text: facts, schema: schema, reasoningEffort: "low",
                                      maxOutputTokens: 2000, timeout: 240)
        }
        return ((try? JSONSerialization.jsonObject(with: reply.json)) as? [String: Any])?["letter"] as? String ?? ""
    }
}
