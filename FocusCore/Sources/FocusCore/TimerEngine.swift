import Foundation
import SwiftData
import Combine
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

/// Platform-agnostic focus-timer engine usable on iOS/iPadOS (and conceptually
/// macOS, though the macOS app currently uses its own TimerManager with
/// site-blocking and AppKit integrations).
///
/// The engine owns no UI. It exposes published state, mutates a SwiftData
/// store on session completion, and persists a tiny checkpoint so a partial
/// session can resume after force-quit / crash.
@MainActor
public final class FocusTimerEngine: ObservableObject {

    // MARK: - Public state

    public enum Phase: String, Sendable {
        case work, breakPhase
        public var displayName: String { self == .work ? "Focus" : "Break" }
        public var isBreak: Bool { self == .breakPhase }
    }

    @Published public private(set) var phase: Phase = .work
    @Published public private(set) var totalTime: TimeInterval
    @Published public private(set) var timeRemaining: TimeInterval
    @Published public private(set) var isRunning: Bool = false

    @Published public var currentLabel: String = ""
    @Published public var currentBreakKinds: [BreakKind] = []
    @Published public private(set) var lastCompletedLabel: String? = nil
    @Published public private(set) var workSessionsCompletedToday: Int = 0

    /// Live elapsed seconds for the current session — even while paused.
    @Published public private(set) var elapsedSeconds: TimeInterval = 0

    // MARK: - Settings hook

    public struct Settings {
        public var workMinutes: Double
        public var breakMinutes: Double
        public var dailyGoalHours: Int
        public var autoStartBreaks: Bool
        public var autoStartWork: Bool
        public var pauseGraceMinutes: Int

        public init(workMinutes: Double = 25, breakMinutes: Double = 10,
                    dailyGoalHours: Int = 4, autoStartBreaks: Bool = true,
                    autoStartWork: Bool = false, pauseGraceMinutes: Int = 10) {
            self.workMinutes = workMinutes
            self.breakMinutes = breakMinutes
            self.dailyGoalHours = dailyGoalHours
            self.autoStartBreaks = autoStartBreaks
            self.autoStartWork = autoStartWork
            self.pauseGraceMinutes = pauseGraceMinutes
        }
    }

    public var settings: Settings { didSet { applySettingsIfIdle() } }

    // MARK: - Private state

    private let container: ModelContainer
    /// Use the main context so inserts immediately trigger `@Query` updates
    /// in SwiftUI views. Creating a fresh ModelContext per save would commit
    /// to the same store but the view layer's context wouldn't always
    /// refresh in time.
    private var context: ModelContext { container.mainContext }
    private var ticker: AnyCancellable?
    public let stateSync: TimerStateSync
    public let localBroadcast: LocalTimerBroadcast
    private var sessionStartTime: Date?
    private var elapsedBeforePause: TimeInterval = 0
    private var lastResumeTime: Date?
    private static let checkpointKey = "focusTimerEngineCheckpoint"

    // MARK: - Init

    public init(container: ModelContainer, settings: Settings = .init()) {
        self.container = container
        self.settings = settings
        self.totalTime = settings.workMinutes * 60
        self.timeRemaining = settings.workMinutes * 60
        self.stateSync = TimerStateSync(container: container)
        self.localBroadcast = LocalTimerBroadcast(deviceID: stateSync.deviceID)
        recoverPartialSession()
        recomputeTodayCount()
        requestNotificationPermission()

        // Listen for remote changes from other devices via CloudKit.
        stateSync.onRemoteChange = { [weak self] state in
            self?.applyRemoteState(state)
        }
        stateSync.onCommands = { [weak self] cmds in
            for c in cmds { self?.apply(c) }
        }
        // Listen for instant local broadcasts (same wifi).
        localBroadcast.onMessage = { [weak self] msg in
            self?.applyRemoteMessage(msg)
        }
        // When a new peer joins Multipeer, immediately rebroadcast our
        // current state. Without this, a session that started before the
        // peer was reachable would be invisible to the peer (CloudKit
        // silent push is unreliable, especially Mac side).
        localBroadcast.onPeerConnected = { [weak self] in
            guard let self else { return }
            // Only re-broadcast if WE have something the peer needs to know
            // about. If we're idle, broadcasting idle to a peer that's
            // running would clobber their session.
            guard self.isActive else {
                SyncLog.event("mpPeerConnectSkip", ["reason": "localIdle"])
                return
            }
            SyncLog.event("mpPeerConnectRebroadcast", [
                "phase": self.phase.rawValue,
                "isRunning": self.isRunning,
            ])
            self.pushSharedState()
        }
        // On launch, adopt the shared state if we're locally idle and
        // the stored state is meaningful (version > 0, non-idle). NO
        // deviceID filter here — at startup our in-memory state is empty,
        // so adopting a previous own-device write IS the recovery path
        // we want. The deviceID/version filtering only matters for
        // steady-state echo-suppression in checkForRemote().
        if !isActive,
           let s = stateSync.currentState(),
           s.version > 0,
           s.phase != StoredTimerState.Phase.idle {
            // Stale running snapshot (would have completed before now)?
            // Push idle so all devices converge on "session over" rather
            // than presenting a ghost timer.
            if s.isRunning, let end = s.endTime, end.timeIntervalSinceNow < -5 {
                stateSync.pushIdle()
            } else {
                applyRemoteState(s)
            }
        }

        #if canImport(UIKit)
        // Resume / refresh state when the app comes back from background.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.didBecomeActive() }
        }
        #endif
    }

    // MARK: - Notifications

    private static let notifIdentifier = "focusTimerCompletion"

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Schedule a local notification at the expected completion moment so the
    /// user hears the bell even if the app is backgrounded or the screen is off.
    private func scheduleCompletionNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notifIdentifier])
        guard timeRemaining > 1, !FocusCategories.isOpenEnded(total: totalTime) else { return }
        let content = UNMutableNotificationContent()
        content.title = phase == .work ? "Focus complete" : "Break over"
        content.body = "Still tracking until you switch."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeRemaining, repeats: false)
        let req = UNNotificationRequest(identifier: Self.notifIdentifier, content: content, trigger: trigger)
        center.add(req)
    }

    private func cancelCompletionNotification() {
        let center = UNUserNotificationCenter.current()
        // Cancel future + clear any already-delivered (so if user comes back
        // after a stale notification fired, it disappears from the lock
        // screen / notification center once we realize the state is paused).
        center.removePendingNotificationRequests(withIdentifiers: [Self.notifIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notifIdentifier])
    }

    // MARK: - Computed

    public var isActive: Bool { isRunning || timeRemaining < totalTime }
    public var isOnBreak: Bool { phase.isBreak }

    public var progress: Double { FocusCategories.progress(total: totalTime, remaining: timeRemaining) }

    public var timeString: String { FocusCategories.timeString(total: totalTime, remaining: timeRemaining) }

    // MARK: - Public controls

    public func start() {
        SyncLog.event("localStart", [
            "phase": phase.rawValue,
            "totalTime": totalTime,
            "timeRemaining": timeRemaining,
            "label": currentLabel,
        ])
        if sessionStartTime == nil { sessionStartTime = Date() }
        lastResumeTime = Date()
        isRunning = true
        ticker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
        saveCheckpoint()
        scheduleCompletionNotification()
        pushSharedState()
    }

    public func pause() {
        SyncLog.event("localPause", [
            "phase": phase.rawValue,
            "timeRemaining": timeRemaining,
        ])
        if let resume = lastResumeTime {
            elapsedBeforePause += Date().timeIntervalSince(resume)
        }
        lastResumeTime = nil
        isRunning = false
        ticker?.cancel(); ticker = nil
        saveCheckpoint()
        cancelCompletionNotification()
        pushSharedState()
    }

    // MARK: - Cross-device state sync

    /// We no longer use a time-based "ignore round-trip" gate — the version
    /// counter in StoredTimerState + the deviceID stamp give us a definitive
    /// answer for "is this our own echo" or "is this newer than what we have".
    /// The old 3s gate was actively harmful: if a peer pushed a newer state
    /// within 3s of our push, we'd drop it.

    private func pushSharedState() {
        let sharedPhase: StoredTimerState.Phase
        switch phase {
        case .work:       sharedPhase = isActive ? .work : .idle
        case .breakPhase: sharedPhase = isActive ? .breakPhase : .idle
        }
        let kinds = currentBreakKinds
        let label = currentLabel
        let start = sessionStartTime
        let total = totalTime
        let isRun = isRunning
        let remaining = timeRemaining
        let endTime = isRun ? Date().addingTimeInterval(remaining) : nil

        // 1) Instant: broadcast to same-wifi peers.
        let msg = LocalTimerBroadcast.Message(
            deviceID: stateSync.deviceID,
            phase: sharedPhase.rawValue,
            isRunning: isRun,
            totalSeconds: total,
            label: label,
            breakKindsRaw: kinds.map(\.rawValue),
            startTime: start,
            endTime: endTime,
            remainingSeconds: remaining,
            timestamp: Date()
        )
        localBroadcast.send(msg)

        // 2) Durable: write to CloudKit-backed SwiftData (catches devices that aren't reachable).
        stateSync.push { state in
            state.phase = sharedPhase
            state.isRunning = isRun
            state.totalSeconds = total
            state.label = label
            state.breakKindsRaw = kinds.map(\.rawValue)
            state.startTime = start
            state.endTime = endTime
            state.remainingSeconds = remaining
        }
    }

    private func pushIdleEverywhere() {
        let msg = LocalTimerBroadcast.Message(
            deviceID: stateSync.deviceID,
            phase: "idle",
            isRunning: false,
            totalSeconds: 0,
            label: "",
            breakKindsRaw: [],
            startTime: Date?.none,
            endTime: Date?.none,
            remainingSeconds: 0,
            timestamp: Date()
        )
        localBroadcast.send(msg)
        stateSync.pushIdle()
    }

    /// Apply a state message received via the instant local broadcast.
    /// (Multipeer messages are self-filtered against `deviceID == self`, so we
    /// don't need the version gate here — only TimerStateSync's CloudKit path
    /// needs it.)
    private func applyRemoteMessage(_ msg: LocalTimerBroadcast.Message) {
        guard let phaseEnum = StoredTimerState.Phase(rawValue: msg.phase) else { return }
        SyncLog.event("applyMp", [
            "phase": msg.phase,
            "isRunning": msg.isRunning,
            "totalSeconds": msg.totalSeconds,
            "endTime": SyncLog.opt(msg.endTime),
            "remaining": msg.remainingSeconds,
            "msgTs": msg.timestamp,
            "localBefore": [
                "phase": phase.rawValue,
                "isRunning": isRunning,
                "totalTime": totalTime,
                "timeRemaining": timeRemaining,
            ],
        ])
        if phaseEnum == .idle {
            // CRITICAL: a remote idle arriving while WE have an active session
            // would silently destroy minutes/hours of work. Save first, then
            // reset. (Triggered by e.g. peer launching and sending a stale
            // idle broadcast, or by a CK row whose authoring device wrongly
            // wiped its state.)
            savePartialIfActive(reason: "remoteIdleMp")
            ticker?.cancel(); ticker = nil
            isRunning = false
            elapsedBeforePause = 0
            lastResumeTime = nil
            sessionStartTime = nil
            elapsedSeconds = 0
            phase = .work
            totalTime = settings.workMinutes * 60
            timeRemaining = totalTime
            currentBreakKinds = []
            cancelCompletionNotification()
            return
        }
        closeSegmentIfReplaced(by: msg.startTime)
        phase = (phaseEnum == .work) ? .work : .breakPhase
        totalTime = msg.totalSeconds
        currentLabel = msg.label
        currentBreakKinds = msg.breakKindsRaw.compactMap { BreakKind(rawValue: $0) }
        sessionStartTime = msg.startTime
        if msg.isRunning, let end = msg.endTime, end.timeIntervalSinceNow > -5 {
            // "Running" with end far in the past = stale snapshot from a peer
            // we hadn't synced with in a while. Don't start a ticker that will
            // immediately auto-complete and possibly insert a phantom session.
            let remaining = max(0, end.timeIntervalSinceNow)
            timeRemaining = remaining
            elapsedBeforePause = totalTime - remaining
            lastResumeTime = Date()
            isRunning = true
            ticker?.cancel()
            ticker = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
            scheduleCompletionNotification()
        } else {
            timeRemaining = msg.remainingSeconds
            elapsedBeforePause = totalTime - msg.remainingSeconds
            lastResumeTime = nil
            isRunning = false
            ticker?.cancel(); ticker = nil
            cancelCompletionNotification()
        }
    }

    private func applyRemoteState(_ state: StoredTimerState) {
        let remotePhase = state.phase
        SyncLog.event("applyCk", [
            "version": state.version,
            "phase": remotePhase.rawValue,
            "isRunning": state.isRunning,
            "totalSeconds": state.totalSeconds,
            "endTime": SyncLog.opt(state.endTime),
            "fromDevice": String(state.deviceID.prefix(8)),
            "updatedAt": state.updatedAt,
            "localBefore": [
                "phase": phase.rawValue,
                "isRunning": isRunning,
                "totalTime": totalTime,
                "timeRemaining": timeRemaining,
            ],
        ])
        if remotePhase == .idle {
            // "Remote trusted to have saved" was wrong — if the remote idle
            // arrives from a peer that was *just opened* (and broadcast its
            // own idle state without knowing we were running), the remote
            // never saved our session. Save partial first.
            savePartialIfActive(reason: "remoteIdleCk")
            ticker?.cancel(); ticker = nil
            isRunning = false
            elapsedBeforePause = 0
            lastResumeTime = nil
            sessionStartTime = nil
            elapsedSeconds = 0
            phase = .work
            totalTime = settings.workMinutes * 60
            timeRemaining = totalTime
            currentBreakKinds = []
            cancelCompletionNotification()
            return
        }

        closeSegmentIfReplaced(by: state.startTime)
        phase = (remotePhase == .work) ? .work : .breakPhase
        totalTime = state.totalSeconds
        currentLabel = state.label
        currentBreakKinds = state.breakKinds
        sessionStartTime = state.startTime

        if state.isRunning, let end = state.endTime, end.timeIntervalSinceNow > -5 {
            // See note in applyRemoteMessage: stale running-snapshots with
            // endTime far in the past would otherwise auto-complete and
            // possibly insert a phantom session. Treat those as paused/idle.
            let remaining = max(0, end.timeIntervalSinceNow)
            timeRemaining = remaining
            elapsedBeforePause = totalTime - remaining
            lastResumeTime = Date()
            isRunning = true
            ticker?.cancel()
            ticker = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
            scheduleCompletionNotification()
        } else {
            // Paused remotely (or stale "running" with past endTime — same
            // outcome: don't tick, just show frozen.)
            timeRemaining = state.remainingSeconds
            elapsedBeforePause = totalTime - state.remainingSeconds
            lastResumeTime = nil
            isRunning = false
            ticker?.cancel(); ticker = nil
            cancelCompletionNotification()
        }
    }

    public func toggleRunPause() {
        if isRunning { pause() } else { start() }
    }

    // MARK: - Switching

    private func elapsed(until date: Date) -> TimeInterval {
        var e = elapsedBeforePause
        if let resume = lastResumeTime { e += max(0, date.timeIntervalSince(resume)) }
        return e
    }

    /// Save the current session as ending at `date` (if ≥ 1 min).
    private func closeSegment(at date: Date) {
        guard let start = sessionStartTime else { return }
        let e = elapsed(until: date)
        guard e >= 60 else { return }
        let isWork = phase == .work
        insertSession(WorkSession(
            startTime: start, durationMinutes: e / 60.0,
            type: isWork ? .work : .shortBreak,
            label: isWork ? (currentLabel.isEmpty ? nil : currentLabel) : nil,
            breakKinds: isWork ? nil : (currentBreakKinds.isEmpty ? nil : currentBreakKinds)
        ))
    }

    /// A peer's state for a *different* session means it switched without
    /// necessarily knowing about ours — save ours (insertSession dedups).
    private func closeSegmentIfReplaced(by newStart: Date?) {
        guard isActive, let start = sessionStartTime, let newStart,
              abs(newStart.timeIntervalSince(start)) > 3 else { return }
        closeSegment(at: newStart > start ? newStart : Date())
    }

    private func beginSession(phase newPhase: Phase, label: String, kinds: [BreakKind],
                              plannedSeconds: TimeInterval, at date: Date) {
        let lead = max(0, Date().timeIntervalSince(date))
        ticker?.cancel(); ticker = nil
        isRunning = false
        phase = newPhase
        currentLabel = label
        currentBreakKinds = kinds
        totalTime = max(plannedSeconds, lead + 60)
        timeRemaining = totalTime - lead
        sessionStartTime = date
        elapsedBeforePause = lead
        elapsedSeconds = lead
        lastResumeTime = nil
        start()
    }

    /// Split the timeline at `date`: what was running is saved up to then and
    /// focus on `label` runs from then. Under a minute of focus is relabeled.
    public func switchTo(_ label: String, at requested: Date = Date()) {
        var date = min(requested, Date())
        if let start = sessionStartTime { date = max(date, start) }
        if phase == .work, isActive {
            if label == currentLabel {
                if !isRunning { start() }
                return
            }
            if elapsed(until: date) < 60 {
                currentLabel = label
                if FocusCategories.isLife(label) && !FocusCategories.isOpenEnded(total: totalTime) {
                    totalTime += FocusCategories.openEndedSeconds
                    timeRemaining += FocusCategories.openEndedSeconds
                    cancelCompletionNotification()
                }
                if isRunning { saveCheckpoint(); pushSharedState() } else { start() }
                return
            }
        }
        closeSegment(at: date)
        cancelCompletionNotification()
        beginSession(phase: .work, label: label, kinds: [],
                     plannedSeconds: FocusCategories.isLife(label) ? FocusCategories.openEndedSeconds : settings.workMinutes * 60,
                     at: date)
    }

    public func stop(at requested: Date) {
        var date = min(requested, Date())
        if let start = sessionStartTime { date = max(date, start) }
        closeSegment(at: date)
        ticker?.cancel(); ticker = nil
        isRunning = false
        cancelCompletionNotification()
        pushIdleEverywhere()
        resetSessionState()
        currentBreakKinds = []
        phase = .work
        totalTime = settings.workMinutes * 60
        timeRemaining = totalTime
    }

    public func startBreak(minutes: Double, kinds: [BreakKind] = [], at requested: Date = Date()) {
        var date = min(requested, Date())
        if let start = sessionStartTime { date = max(date, start) }
        if phase == .work { closeSegment(at: date) }
        cancelCompletionNotification()
        beginSession(phase: .breakPhase, label: currentLabel, kinds: kinds,
                     plannedSeconds: minutes > 0 ? minutes * 60 : FocusCategories.openEndedSeconds, at: date)
    }

    public func apply(_ command: TimerCommand) {
        switch command.action {
        case .switchTo:
            guard !command.label.isEmpty else { return }
            switchTo(command.label, at: command.createdAt)
        case .stop:
            stop(at: command.createdAt)
        case .startBreak:
            startBreak(minutes: command.minutes, at: command.createdAt)
        }
    }

    /// Stop the timer. Saves partial work if ≥ 1 minute elapsed.
    public func stop() {
        finalize(saveAsCompleted: false)
    }

    /// Skip forward — saves a partial break if ≥ 5 minutes, then returns to
    /// work-idle. During work this behaves like stop().
    public func skip() {
        if phase.isBreak {
            finalize(saveAsCompleted: false, minBreakMinutes: 5)
        } else {
            finalize(saveAsCompleted: false)
        }
    }

    /// Quick presets while idle (15 / 25 / 45 / 60 min etc.).
    public func setSessionDuration(_ minutes: Double) {
        guard !isActive else { return }
        totalTime = minutes * 60
        timeRemaining = minutes * 60
        // No push here — idle preset change is local until Start.
    }

    /// Mid-session ±N minute nudge.
    public func adjustDuration(by minutes: Double) {
        let newRemaining = timeRemaining + minutes * 60
        guard newRemaining > 5 else { completePhase(); return }
        totalTime = max(60, totalTime + minutes * 60)
        timeRemaining = newRemaining
        if isRunning { scheduleCompletionNotification() }
        pushSharedState()
    }

    /// Take-a-break from idle (or interrupting work) — saves partial work
    /// first, then runs a break of `minutes` with the chosen kinds.
    public func startManualBreak(minutes: Double, kinds: [BreakKind] = []) {
        // Save any partial work first.
        if phase == .work, let start = sessionStartTime {
            let elapsed = currentElapsedSeconds
            if elapsed >= 60 {
                insertSession(WorkSession(
                    startTime: start, durationMinutes: elapsed / 60.0,
                    type: .work, label: currentLabel.isEmpty ? nil : currentLabel
                ))
            }
        }
        resetSessionState()
        phase = .breakPhase
        currentBreakKinds = kinds
        totalTime = minutes > 0 ? minutes * 60 : FocusCategories.openEndedSeconds
        timeRemaining = totalTime
        start()
        // start() already pushes state
    }

    // MARK: - Private machinery

    private var currentElapsedSeconds: TimeInterval {
        var e = elapsedBeforePause
        if let resume = lastResumeTime { e += Date().timeIntervalSince(resume) }
        return e
    }

    /// If we have an in-progress local session with at least 60s elapsed,
    /// persist it to SessionStore before any caller wipes the engine state.
    /// Called from every code path that resets state due to a *remote*
    /// signal (idle from CK or Multipeer) — without this we silently
    /// throw away the user's accumulated time.
    private func savePartialIfActive(reason: String) {
        guard let start = sessionStartTime else { return }
        let elapsed = currentElapsedSeconds
        guard elapsed >= 60 else {
            SyncLog.event("savePartialSkip", [
                "reason": reason,
                "elapsed": elapsed,
                "phase": phase.rawValue,
            ])
            return
        }
        let type: WorkSession.SessionType = (phase == .work) ? .work : .shortBreak
        let kinds = currentBreakKinds.isEmpty ? nil : currentBreakKinds
        let label = currentLabel.isEmpty ? nil : currentLabel
        SyncLog.event("savePartial", [
            "reason": reason,
            "elapsedMin": elapsed / 60.0,
            "phase": phase.rawValue,
            "label": label ?? "",
            "startTime": start,
        ])
        insertSession(WorkSession(
            startTime: start,
            durationMinutes: elapsed / 60.0,
            type: type,
            label: type == .work ? label : nil,
            breakKinds: type == .work ? nil : kinds
        ))
    }

    private func tick() {
        guard let resume = lastResumeTime else { return }
        let elapsed = elapsedBeforePause + Date().timeIntervalSince(resume)
        elapsedSeconds = elapsed
        timeRemaining = max(0, totalTime - elapsed)
        if timeRemaining <= 0 { extendRunway() }
    }

    /// Nothing ends on its own: a finished countdown rolls into overtime and
    /// keeps tracking. The completion notification already fired on schedule.
    private func extendRunway() {
        if phase == .work && !FocusCategories.isOpenEnded(total: totalTime) {
            lastCompletedLabel = currentLabel.isEmpty ? nil : currentLabel
            workSessionsCompletedToday += 1
        }
        totalTime += FocusCategories.openEndedSeconds
        timeRemaining += FocusCategories.openEndedSeconds
        saveCheckpoint()
        pushSharedState()
    }

    private func completePhase() {
        ticker?.cancel(); ticker = nil
        isRunning = false
        pushIdleEverywhere()

        if let start = sessionStartTime {
            let type: WorkSession.SessionType = phase == .work ? .work : .shortBreak
            insertSession(WorkSession(
                startTime: start,
                durationMinutes: totalTime / 60.0,
                type: type,
                label: phase == .work ? (currentLabel.isEmpty ? nil : currentLabel) : nil,
                breakKinds: phase == .work ? nil : (currentBreakKinds.isEmpty ? nil : currentBreakKinds)
            ))
        }

        if phase == .work {
            lastCompletedLabel = currentLabel.isEmpty ? nil : currentLabel
            workSessionsCompletedToday += 1
            resetSessionState()
            if settings.autoStartBreaks {
                phase = .breakPhase
                totalTime = settings.breakMinutes * 60
                timeRemaining = totalTime
                start()
            } else {
                phase = .work
                totalTime = settings.workMinutes * 60
                timeRemaining = totalTime
            }
        } else {
            resetSessionState()
            currentBreakKinds = []
            phase = .work
            totalTime = settings.workMinutes * 60
            timeRemaining = totalTime
            if settings.autoStartWork { start() }
        }
    }

    /// `minBreakMinutes` lets skip-during-break ignore tiny break flicks.
    private func finalize(saveAsCompleted: Bool, minBreakMinutes: Double = 1.0) {
        ticker?.cancel(); ticker = nil
        isRunning = false
        cancelCompletionNotification()
        pushIdleEverywhere()
        let elapsed = currentElapsedSeconds

        if let start = sessionStartTime {
            let mins = elapsed / 60.0
            let threshold = phase.isBreak ? minBreakMinutes : 1.0
            if mins >= threshold {
                let type: WorkSession.SessionType = phase == .work ? .work : .shortBreak
                insertSession(WorkSession(
                    startTime: start, durationMinutes: mins,
                    type: type,
                    label: phase == .work ? (currentLabel.isEmpty ? nil : currentLabel) : nil,
                    breakKinds: phase == .work ? nil : (currentBreakKinds.isEmpty ? nil : currentBreakKinds)
                ))
            }
        }

        resetSessionState()
        currentBreakKinds = []
        phase = .work
        totalTime = settings.workMinutes * 60
        timeRemaining = totalTime
    }

    private func resetSessionState() {
        elapsedBeforePause = 0
        lastResumeTime = nil
        sessionStartTime = nil
        elapsedSeconds = 0
        clearCheckpoint()
    }

    private func applySettingsIfIdle() {
        guard !isActive else { return }
        switch phase {
        case .work:
            totalTime = settings.workMinutes * 60
        case .breakPhase:
            totalTime = settings.breakMinutes * 60
        }
        timeRemaining = totalTime
    }

    private func insertSession(_ s: WorkSession) {
        let ctx = context
        // Dedup: when the same timer completes on Mac + iPad simultaneously,
        // each device's engine calls insertSession independently. Look up
        // any existing session within ±3s of this startTime with the same
        // type + label and skip the insert if it's already there. CloudKit
        // doesn't support unique constraints so this is the safest spot.
        let start = s.startTime
        let lower = start.addingTimeInterval(-3)
        let upper = start.addingTimeInterval(3)
        let typeRaw = s.type.rawValue
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { existing in
                existing.startTime >= lower &&
                existing.startTime <= upper &&
                existing.typeRaw == typeRaw
            }
        )
        if let dupes = try? ctx.fetch(descriptor),
           dupes.contains(where: { $0.label == s.label }) {
            return
        }
        ctx.insert(StoredWorkSession(value: s))
        try? ctx.save()
        if s.type == .work {
            recomputeTodayCount()
        }
    }

    private func recomputeTodayCount() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { $0.startTime >= start && $0.typeRaw == "work" }
        )
        let count = (try? context.fetch(descriptor).count) ?? 0
        workSessionsCompletedToday = count
    }

    // MARK: - Checkpoint

    private func saveCheckpoint() {
        guard phase == .work, let start = sessionStartTime else {
            clearCheckpoint(); return
        }
        var data: [String: Any] = [
            "sessionStartTime": start.timeIntervalSince1970,
            "elapsedBeforePause": elapsedBeforePause,
            "totalTime": totalTime,
            "currentLabel": currentLabel
        ]
        if let r = lastResumeTime { data["lastResumeTime"] = r.timeIntervalSince1970 }
        UserDefaults.standard.set(data, forKey: Self.checkpointKey)
    }

    private func clearCheckpoint() {
        UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
    }

    private func recoverPartialSession() {
        guard let data = UserDefaults.standard.dictionary(forKey: Self.checkpointKey),
              let startEpoch = data["sessionStartTime"] as? Double,
              let elapsed0 = data["elapsedBeforePause"] as? Double,
              let total = data["totalTime"] as? Double
        else { return }
        clearCheckpoint()

        var elapsed = elapsed0
        let wasRunning = data["lastResumeTime"] != nil
        if let r = data["lastResumeTime"] as? Double {
            elapsed += Date().timeIntervalSince(Date(timeIntervalSince1970: r))
        }
        let label = (data["currentLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        if elapsed >= total {
            if total >= 60 {
                let ctx = context
                ctx.insert(StoredWorkSession(value: WorkSession(
                    startTime: Date(timeIntervalSince1970: startEpoch),
                    durationMinutes: total / 60.0,
                    type: .work,
                    label: label
                )))
                try? ctx.save()
            }
            return
        }

        phase = .work
        totalTime = total
        timeRemaining = total - elapsed
        elapsedBeforePause = elapsed
        sessionStartTime = Date(timeIntervalSince1970: startEpoch)
        currentLabel = label ?? ""
        if wasRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.start()
            }
        }
    }

    private func didBecomeActive() {
        // 1) Reconcile with shared state — another device may have paused
        //    or stopped while we were backgrounded. Read what's already in the
        //    local CloudKit mirror, AND re-check after a short delay because
        //    silent-push driven CloudKit imports can land moments after
        //    `didBecomeActive` fires.
        if let shared = stateSync.currentState(),
           shared.deviceID != stateSync.deviceID,
           shared.version > 0 {
            applyRemoteState(shared)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.stateSync.pokeForRemote()
        }

        // 2) If the timer is no longer running for any reason (just got
        //    paused above, or local pause we forgot to clean up), wipe
        //    any pending OR already-delivered completion notification.
        if !isRunning {
            cancelCompletionNotification()
        }

        // 3) Reconcile elapsed against wall-clock — fixes drift while suspended.
        if isRunning, let resume = lastResumeTime {
            let elapsed = elapsedBeforePause + Date().timeIntervalSince(resume)
            elapsedSeconds = elapsed
            timeRemaining = max(0, totalTime - elapsed)
            while timeRemaining <= 0 {
                extendRunway()
                timeRemaining = max(0, totalTime - elapsed)
            }
        }
        recomputeTodayCount()
    }
}
