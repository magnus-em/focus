import Foundation
import FocusCore
import Combine
import UserNotifications
import AppKit

class TimerManager: ObservableObject {
    @Published var timeRemaining: TimeInterval
    @Published var totalTime: TimeInterval
    @Published var isRunning = false
    @Published var currentPhase: Phase = .work
    @Published var workSessionsCompleted: Int = 0
    @Published var isBlockingActive = false

    @Published var currentLabel: String = "" {
        didSet { if !isActive && currentPhase == .work && currentLabel != oldValue { setTimeForCurrentPhase() } }
    }
    @Published var lastCompletedLabel: String? = nil
    @Published var currentBreakKinds: [BreakKind] = []

    @Published var pauseStartedAt: Date? = nil
    @Published var pauseRemainingSeconds: Double = 0
    private var pauseStaleSubscription: AnyCancellable?

    enum Phase {
        case work, shortBreak, longBreak
        var displayName: String { self == .work ? "Focus" : "Break" }
    }

    private var timer: AnyCancellable?
    private(set) var sessionStartTime: Date? {
        didSet { if let s = sessionStartTime { lastSessionStart = s } }
    }
    /// The most recent session's start, still known after it ends: sent with
    /// the idle state so peers know which session was stopped.
    private var lastSessionStart: Date?
    private var elapsedBeforePause: TimeInterval = 0
    private var lastResumeTime: Date?
    private var settingsSubscriptions = Set<AnyCancellable>()
    private let completionPanel = CompletionPanel()
    private var tickCount = 0
    private static let checkpointKey = "timerCheckpoint"

    var sessionStore: SessionStore?
    /// Fired after a command from another device (phone Shortcut, etc.) is applied.
    var onCommandApplied: ((TimerCommand) -> Void)?
    /// Fired when a focus segment is saved because the user switched, stopped
    /// or took a break (not on auto-finalize or crash recovery).
    var onFocusSegmentSaved: ((WorkSession) -> Void)?
    var settings: AppSettings? { didSet { observeSettingsChanges() } }

    /// Cross-device live-timer sync. Set externally after init.
    var stateSync: TimerStateSync? {
        didSet {
            stateSync?.onRemoteChange = { [weak self] state in
                self?.applyRemoteState(state)
            }
            stateSync?.onCommands = { [weak self] cmds in
                guard let self else { return }
                for c in cmds { self.apply(c) }
                if let last = cmds.last { self.onCommandApplied?(last) }
            }
            // On launch, adopt the shared state if (a) we're idle locally
            // and (b) the stored state is meaningful (version > 0, not idle).
            //
            // We DON'T filter by `deviceID != self` here — that filter is for
            // *steady-state* echoes, where we want to ignore our own writes
            // bouncing back via CloudKit. At startup we have no in-memory
            // state to clobber, and adopting our own previously-written
            // state is exactly the recovery we want: e.g., user starts a
            // break on Mac, app gets killed, Mac re-launches → we should
            // pick up where we left off rather than show idle while the
            // CK record says "break running".
            if !isActive,
               let s = stateSync?.currentState(),
               s.version > 0,
               s.phase != StoredTimerState.Phase.idle {
                // Stale running snapshot (would have completed before now)?
                // Don't adopt as paused-with-leftover — that just shows a
                // ghost timer the user can't get rid of. Push idle so all
                // devices converge on "session over, fresh start."
                if s.isRunning, let end = s.endTime, end.timeIntervalSinceNow < -5 {
                    stateSync?.pushIdle()
                } else {
                    applyRemoteState(s)
                }
            }
        }
    }
    var localBroadcast: LocalTimerBroadcast? {
        didSet {
            localBroadcast?.onMessage = { [weak self] msg in
                self?.applyRemoteMessage(msg)
            }
            // When a peer reconnects, rebroadcast our current state so they
            // see any session that started before the link was up.
            localBroadcast?.onPeerConnected = { [weak self] in
                guard let self else { return }
                guard self.isActive else {
                    SyncLog.event("mpPeerConnectSkip", ["reason": "localIdle"])
                    return
                }
                SyncLog.event("mpPeerConnectRebroadcast", [
                    "phase": self.phaseKey(self.currentPhase),
                    "isRunning": self.isRunning,
                ])
                self.pushSharedState()
            }
        }
    }
    /// No time-based echo gate anymore — TimerStateSync's version field +
    /// deviceID stamp give us a definitive "is this our echo / is this newer"
    /// answer. The old 3s window would suppress legitimate newer peer pushes
    /// that arrived while CloudKit was still processing our own.

    private var workDuration: TimeInterval { (settings?.workMinutes ?? 25) * 60 }
    private var breakDuration: TimeInterval { (settings?.shortBreakMinutes ?? 10) * 60 }

    init() {
        self.totalTime = 25 * 60
        self.timeRemaining = 25 * 60
        requestNotificationPermission()
    }

    func applySettings() {
        guard !isRunning && elapsedBeforePause == 0 else { return }
        setTimeForCurrentPhase()
    }

    // MARK: - Display

    var progress: Double { FocusCategories.progress(total: totalTime, remaining: timeRemaining) }

    var timeString: String { FocusCategories.timeString(total: totalTime, remaining: timeRemaining) }

    var isActive: Bool { isRunning || timeRemaining < totalTime }
    var isOnBreak: Bool { currentPhase != .work }

    var menuBarTimeText: String {
        isRunning ? timeString : "⏸ \(timeString)"
    }

    var currentElapsedSeconds: TimeInterval {
        var elapsed = elapsedBeforePause
        if let resume = lastResumeTime { elapsed += Date().timeIntervalSince(resume) }
        return elapsed
    }

    var currentInProgressSession: WorkSession? {
        guard isActive, currentPhase == .work, let start = sessionStartTime else { return nil }
        return WorkSession(
            startTime: start,
            durationMinutes: currentElapsedSeconds / 60.0,
            type: .work,
            label: currentLabel.isEmpty ? nil : currentLabel
        )
    }

    var currentInProgressBreak: WorkSession? {
        guard isActive, isOnBreak, let start = sessionStartTime else { return nil }
        return WorkSession(
            startTime: start,
            durationMinutes: currentElapsedSeconds / 60.0,
            type: .shortBreak,
            label: nil,
            breakKinds: currentBreakKinds.isEmpty ? nil : currentBreakKinds
        )
    }

    // MARK: - Controls

    func start() {
        SyncLog.event("localStart", [
            "phase": phaseKey(currentPhase),
            "totalTime": totalTime,
            "timeRemaining": timeRemaining,
            "label": currentLabel,
        ])
        cancelPauseGrace()
        if sessionStartTime == nil { sessionStartTime = Date() }
        lastResumeTime = Date()
        isRunning = true
        tickCount = 0
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
        updateBlocking()
        saveCheckpoint()
        pushSharedState()
    }

    func pause() {
        SyncLog.event("localPause", [
            "phase": phaseKey(currentPhase),
            "timeRemaining": timeRemaining,
        ])
        if let resumeTime = lastResumeTime {
            elapsedBeforePause += Date().timeIntervalSince(resumeTime)
        }
        lastResumeTime = nil
        isRunning = false
        timer?.cancel()
        timer = nil
        saveCheckpoint()
        if currentPhase == .work && sessionStartTime != nil {
            startPauseGrace()
        }
        pushSharedState()
    }

    // MARK: - Cross-device state sync

    private func pushSharedState() {
        SharedSessionMemory.mark(sessionStartTime)
        guard let stateSync else { return }
        let sharedPhase: StoredTimerState.Phase
        switch currentPhase {
        case .work:       sharedPhase = isActive ? .work : .idle
        case .shortBreak, .longBreak:
            sharedPhase = isActive ? .breakPhase : .idle
        }
        let label = currentLabel
        let kinds = currentBreakKinds
        let start = sessionStartTime
        let total = totalTime
        let isRun = isRunning
        let remaining = timeRemaining
        let endTime = isRun ? Date().addingTimeInterval(remaining) : nil

        // Instant: local broadcast (same-wifi peers)
        if let lb = localBroadcast {
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
            lb.send(msg)
        }

        // Durable: SwiftData → CloudKit
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

    private func pushIdleEverywhere(endedAt: Date = Date()) {
        guard let stateSync else { return }
        if let lb = localBroadcast {
            let msg = LocalTimerBroadcast.Message(
                deviceID: stateSync.deviceID,
                phase: "idle",
                isRunning: false,
                totalSeconds: 0,
                label: "",
                breakKindsRaw: [],
                startTime: lastSessionStart,
                endTime: lastSessionStart == nil ? nil : endedAt,
                remainingSeconds: 0,
                timestamp: Date()
            )
            lb.send(msg)
        }
        stateSync.pushIdle(ended: lastSessionStart, endedAt: endedAt)
    }

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
                "phase": phaseKey(currentPhase),
                "isRunning": isRunning,
                "totalTime": totalTime,
                "timeRemaining": timeRemaining,
            ],
        ])
        if phaseEnum == .idle {
            // Save the in-progress local session before remote idle wipes
            // it. Without this guard, a peer launching and broadcasting
            // its own idle state destroys minutes/hours of our progress.
            savePartialIfActive(reason: "remoteIdleMp", stoppedStart: msg.startTime, stoppedAt: msg.endTime ?? msg.timestamp)
            timer?.cancel(); timer = nil
            isRunning = false
            elapsedBeforePause = 0
            lastResumeTime = nil
            sessionStartTime = nil
            currentPhase = .work
            currentBreakKinds = []
            setTimeForCurrentPhase()
            unblockIfNeeded()
            return
        }
        if rejectOlder(msg.startTime, source: "mp") { return }
        closeSegmentIfReplaced(by: msg.startTime)
        currentPhase = (phaseEnum == .work) ? .work : .shortBreak
        totalTime = msg.totalSeconds
        currentLabel = msg.label
        currentBreakKinds = msg.breakKindsRaw.compactMap { BreakKind(rawValue: $0) }
        sessionStartTime = msg.startTime
        SharedSessionMemory.mark(msg.startTime)
        knowledgeStale = false
        if msg.isRunning, let end = msg.endTime, end.timeIntervalSinceNow > -5 {
            // Stale "running" snapshot (endTime in the past): don't auto-
            // complete and save a phantom session — show frozen instead.
            let remaining = max(0, end.timeIntervalSinceNow)
            timeRemaining = remaining
            elapsedBeforePause = totalTime - remaining
            lastResumeTime = Date()
            isRunning = true
            timer?.cancel()
            tickCount = 0
            timer = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
            updateBlocking()
        } else {
            timeRemaining = msg.remainingSeconds
            elapsedBeforePause = totalTime - msg.remainingSeconds
            lastResumeTime = nil
            isRunning = false
            timer?.cancel(); timer = nil
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
                "phase": phaseKey(currentPhase),
                "isRunning": isRunning,
                "totalTime": totalTime,
                "timeRemaining": timeRemaining,
            ],
        ])
        if remotePhase == .idle {
            // Save partial local session before remote idle wipes it.
            // (Same rationale as applyRemoteMessage's idle branch — a
            // peer that just launched can broadcast an idle that
            // doesn't reflect our actually-running local session.)
            savePartialIfActive(reason: "remoteIdleCk", stoppedStart: state.startTime, stoppedAt: state.endTime ?? state.updatedAt)
            timer?.cancel(); timer = nil
            isRunning = false
            elapsedBeforePause = 0
            lastResumeTime = nil
            sessionStartTime = nil
            currentPhase = .work
            currentBreakKinds = []
            setTimeForCurrentPhase()
            unblockIfNeeded()
            return
        }
        if rejectOlder(state.startTime, source: "ck") { return }
        closeSegmentIfReplaced(by: state.startTime)
        currentPhase = (remotePhase == .work) ? .work : .shortBreak
        totalTime = state.totalSeconds
        currentLabel = state.label
        currentBreakKinds = state.breakKinds
        sessionStartTime = state.startTime
        SharedSessionMemory.mark(state.startTime)
        knowledgeStale = false
        if state.isRunning, let end = state.endTime, end.timeIntervalSinceNow > -5 {
            // Stale "running" snapshot (endTime in the past): treat as paused.
            let remaining = max(0, end.timeIntervalSinceNow)
            timeRemaining = remaining
            elapsedBeforePause = totalTime - remaining
            lastResumeTime = Date()
            isRunning = true
            timer?.cancel()
            tickCount = 0
            timer = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
            updateBlocking()
        } else {
            timeRemaining = state.remainingSeconds
            elapsedBeforePause = totalTime - state.remainingSeconds
            lastResumeTime = nil
            isRunning = false
            timer?.cancel(); timer = nil
        }
    }

    // MARK: - Switching

    /// Seconds of the current session that fall before `date`.
    private func elapsed(until date: Date) -> TimeInterval {
        var e = elapsedBeforePause
        if let resume = lastResumeTime { e += max(0, date.timeIntervalSince(resume)) }
        return e
    }

    /// Save the current session as ending at `date` (if ≥ 1 min). Leaves
    /// timer state alone — callers reset it.
    private func closeSegment(at date: Date, notify: Bool = true) {
        guard let start = sessionStartTime else { return }
        let e = RemoteStop.duration(elapsed: elapsed(until: date), start: start, end: date)
        guard e >= 60 else { return }
        if currentPhase == .work {
            let session = WorkSession(
                startTime: start, durationMinutes: e / 60.0,
                type: .work, label: currentLabel.isEmpty ? nil : currentLabel
            )
            sessionStore?.addSession(session)
            if notify { onFocusSegmentSaved?(session) }
        } else {
            sessionStore?.addSession(WorkSession(
                startTime: start, durationMinutes: e / 60.0,
                type: .shortBreak, label: nil,
                breakKinds: currentBreakKinds.isEmpty ? nil : currentBreakKinds
            ))
        }
    }

    /// A peer announcing a session that began before ours is behind (e.g. an
    /// app relaunched with its old checkpoint): keep ours and re-announce it.
    private func rejectOlder(_ theirStart: Date?, source: String) -> Bool {
        guard isActive, let mine = sessionStartTime, let theirStart,
              theirStart < mine.addingTimeInterval(-3) else { return false }
        SyncLog.event("rejectOlderPeer", ["source": source, "theirs": "\(theirStart)", "mine": "\(mine)"])
        pushSharedState()
        return true
    }

    /// A peer's state describing a *different* session than ours means it
    /// switched; the peer may not have known about ours, so save it here
    /// (SessionStore dedups if the peer saved it too).
    /// Set after sleep/suspension or a checkpoint restore; cleared once the
    /// shared state is applied again or a session is begun here.
    private var knowledgeStale = false
    private var lastAliveAt = Date()

    private func closeSegmentIfReplaced(by newStart: Date?) {
        guard isActive, let start = sessionStartTime, let newStart,
              abs(newStart.timeIntervalSince(start)) > 3 else { return }
        if knowledgeStale && SharedSessionMemory.wasShared(start) {
            SyncLog.event("skipStaleSegment", ["start": "\(start)", "replacedBy": "\(newStart)"])
            return
        }
        closeSegment(at: newStart > start ? newStart : Date())
    }

    /// Begin a session that logically started at `date`, already running.
    private func beginSession(phase: Phase, label: String, kinds: [BreakKind], plannedSeconds: TimeInterval, at date: Date) {
        knowledgeStale = false
        let lead = max(0, Date().timeIntervalSince(date))
        timer?.cancel(); timer = nil
        isRunning = false
        currentPhase = phase
        currentLabel = label
        currentBreakKinds = kinds
        totalTime = max(plannedSeconds, lead + 60)
        timeRemaining = totalTime - lead
        sessionStartTime = date
        elapsedBeforePause = lead
        lastResumeTime = nil
        start()
    }

    /// Split the timeline at `date`: whatever was running is saved up to
    /// then, and focus on `label` runs from then. A focus segment under a
    /// minute is relabeled rather than saved.
    /// Rename the running block without splitting it (undo of a screen
    /// auto-switch). Focus ↔ focus only, so the countdown stays as it is.
    func relabelRunning(_ label: String) {
        guard isActive, currentPhase == .work, label != currentLabel else { return }
        currentLabel = label
        saveCheckpoint()
        pushSharedState()
        updateBlocking()
    }

    func switchTo(_ label: String, at requested: Date = Date()) {
        var date = min(requested, Date())
        if let start = sessionStartTime { date = max(date, start) }
        if currentPhase == .work, isActive {
            if label == currentLabel {
                if !isRunning { start() }
                return
            }
            if elapsed(until: date) < 60 {
                currentLabel = label
                if FocusCategories.isLife(label) && !FocusCategories.isOpenEnded(total: totalTime) {
                    totalTime += FocusCategories.openEndedSeconds
                    timeRemaining += FocusCategories.openEndedSeconds
                }
                if isRunning { saveCheckpoint(); pushSharedState(); updateBlocking() } else { start() }
                return
            }
        }
        cancelPauseGrace()
        closeSegment(at: date)
        beginSession(phase: .work, label: label, kinds: [],
                     plannedSeconds: FocusCategories.isLife(label) ? FocusCategories.openEndedSeconds : workDuration,
                     at: date)
    }

    /// Hand [from, to) of the running block to `label` (nil = break): the
    /// block is saved up to `from`, the span is logged, and the same
    /// category carries on from `to`.
    func carveOut(from: Date, to: Date, as label: String?) {
        guard isRunning, let start = sessionStartTime, from >= start else { return }
        let end = min(to, Date())
        guard end.timeIntervalSince(from) >= 60 else { return }
        let phase = currentPhase, resume = currentLabel, kinds = currentBreakKinds
        cancelPauseGrace()
        closeSegment(at: from, notify: false)
        sessionStore?.fill(start: from, end: end, label: label)
        let openEnded = phase != .work || FocusCategories.isLife(resume)
        beginSession(phase: phase, label: resume, kinds: kinds,
                     plannedSeconds: openEnded ? FocusCategories.openEndedSeconds : workDuration, at: end)
        updateBlocking()
    }

    func stop(at date: Date) {
        cancelPauseGrace()
        let end = max(min(date, Date()), sessionStartTime ?? date)
        closeSegment(at: end)
        timer?.cancel(); timer = nil
        isRunning = false
        currentBreakKinds = []
        elapsedBeforePause = 0
        lastResumeTime = nil
        sessionStartTime = nil
        clearCheckpoint()
        currentPhase = .work
        setTimeForCurrentPhase()
        unblockIfNeeded()
        pushIdleEverywhere(endedAt: end)
    }

    func apply(_ command: TimerCommand) {
        switch command.action {
        case .switchTo:
            guard !command.label.isEmpty else { return }
            switchTo(command.label, at: command.createdAt)
        case .stop:
            stop(at: command.createdAt)
        case .startBreak:
            startManualBreak(minutes: command.minutes, at: command.createdAt)
        }
    }

    enum QuickToggleResult { case started(String), stopped(minutes: Int, label: String) }

    /// One-key start/stop for when opening the popover is too much friction.
    /// Idle or on a break → start focus (keeping a chosen category, else `tag`).
    /// Focus active → stop and save.
    func quickToggle(tag: String) -> QuickToggleResult {
        if currentPhase == .work && isActive {
            let label = currentLabel
            let minutes = Int(currentElapsedSeconds / 60)
            reset()
            return .stopped(minutes: minutes, label: label)
        }
        let label = currentLabel.isEmpty ? tag : currentLabel
        switchTo(label)
        return .started(label)
    }

    func toggleRunPause() {
        if isRunning { pause() }
        else if isActive { start() }
    }

    func reset() {
        stop(at: Date())
    }

    func skip() {
        cancelPauseGrace()
        var elapsed = elapsedBeforePause
        if let resumeTime = lastResumeTime { elapsed += Date().timeIntervalSince(resumeTime) }
        timer?.cancel()
        timer = nil
        isRunning = false

        if currentPhase == .work, elapsed >= 60, let start = sessionStartTime {
            sessionStore?.addSession(WorkSession(
                startTime: start, durationMinutes: elapsed / 60.0,
                type: .work, label: currentLabel.isEmpty ? nil : currentLabel
            ))
        } else if isOnBreak, elapsed >= 60, let start = sessionStartTime {
            sessionStore?.addSession(WorkSession(
                startTime: start, durationMinutes: elapsed / 60.0, type: .shortBreak, label: nil,
                breakKinds: currentBreakKinds.isEmpty ? nil : currentBreakKinds
            ))
        }

        currentBreakKinds = []
        elapsedBeforePause = 0
        lastResumeTime = nil
        sessionStartTime = nil
        clearCheckpoint()
        currentPhase = .work
        setTimeForCurrentPhase()
        updateBlocking()
        pushIdleEverywhere()
    }

    func startManualBreak(minutes: Double, kinds: [BreakKind] = [], at requested: Date = Date()) {
        var date = min(requested, Date())
        if let start = sessionStartTime { date = max(date, start) }
        cancelPauseGrace()
        if currentPhase == .work { closeSegment(at: date) }
        clearCheckpoint()
        beginSession(phase: .shortBreak, label: currentLabel, kinds: kinds,
                     plannedSeconds: minutes > 0 ? minutes * 60 : FocusCategories.openEndedSeconds, at: date)
        updateBlocking()
    }

    func adjustDuration(by minutes: Double) {
        let newRemaining = timeRemaining + minutes * 60
        guard newRemaining > 5 else { completePhase(); return }
        totalTime = max(60, totalTime + minutes * 60)
        timeRemaining = newRemaining
    }

    func setSessionDuration(_ minutes: Double) {
        guard !isActive else { return }
        totalTime = minutes * 60
        timeRemaining = minutes * 60
    }

    // MARK: - Pause grace

    private var pauseGraceSeconds: Double {
        Double(max(1, settings?.pauseGraceMinutes ?? 10)) * 60
    }

    private func startPauseGrace() {
        pauseStartedAt = Date()
        pauseRemainingSeconds = pauseGraceSeconds
        pauseStaleSubscription = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickPauseGrace() }
    }

    private func tickPauseGrace() {
        guard let started = pauseStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        pauseRemainingSeconds = max(0, pauseGraceSeconds - elapsed)
        if pauseRemainingSeconds <= 0 { finalizeStalePause() }
    }

    private func cancelPauseGrace() {
        pauseStaleSubscription?.cancel()
        pauseStaleSubscription = nil
        pauseStartedAt = nil
        pauseRemainingSeconds = 0
    }

    private func finalizeStalePause() {
        cancelPauseGrace()
        let elapsed = elapsedBeforePause
        if elapsed >= 60, currentPhase == .work, let start = sessionStartTime {
            sessionStore?.addSession(WorkSession(
                startTime: start, durationMinutes: elapsed / 60.0,
                type: .work, label: currentLabel.isEmpty ? nil : currentLabel
            ))
        }
        elapsedBeforePause = 0
        lastResumeTime = nil
        sessionStartTime = nil
        clearCheckpoint()
        currentPhase = .work
        setTimeForCurrentPhase()
        unblockIfNeeded()
        pushIdleEverywhere()
        sendStaleEndedNotification()
    }

    private func sendStaleEndedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Focus"
        content.body = "Paused too long — session ended and saved."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Timer logic

    private func tick() {
        let now = Date()
        // Ticks stop while suspended/asleep: past that, others may have moved on.
        if now.timeIntervalSince(lastAliveAt) > 120 { knowledgeStale = true }
        lastAliveAt = now
        guard let resumeTime = lastResumeTime else { return }
        let elapsed = elapsedBeforePause + Date().timeIntervalSince(resumeTime)
        timeRemaining = max(0, totalTime - elapsed)
        if timeRemaining <= 0 { extendRunway(); return }
        tickCount += 1
        if tickCount % 60 == 0 { saveCheckpoint() }
    }

    /// Nothing ends on its own: a finished countdown rolls into overtime and
    /// keeps tracking until the user switches or stops.
    private func extendRunway() {
        let wasCountdown = !FocusCategories.isOpenEnded(total: totalTime)
        totalTime += FocusCategories.openEndedSeconds
        timeRemaining += FocusCategories.openEndedSeconds
        saveCheckpoint()
        pushSharedState()
        guard wasCountdown else { return }

        if settings?.soundEnabled ?? true { NSSound(named: "Glass")?.play() }
        if currentPhase == .work {
            workSessionsCompleted += 1
            lastCompletedLabel = currentLabel.isEmpty ? nil : currentLabel
            completionPanel.show(label: lastCompletedLabel) { [weak self] action in
                guard let self, action == .takeBreak else { return }
                self.startManualBreak(minutes: 0)
            }
        } else {
            let content = UNMutableNotificationContent()
            content.title = "Focus"
            content.body = "Break's up — still tracking it until you switch."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }

    private func completePhase() {
        timer?.cancel()
        timer = nil
        isRunning = false
        // Tell peers we're done with this phase so their shared state
        // doesn't remain in the stale "running with past endTime" form.
        // Auto-break / Keep-Going will overwrite this with a fresh start
        // a moment later if applicable.
        pushIdleEverywhere()

        if let start = sessionStartTime {
            let type: WorkSession.SessionType = currentPhase == .work ? .work : .shortBreak
            let kinds: [BreakKind]? = currentPhase == .work ? nil : (currentBreakKinds.isEmpty ? nil : currentBreakKinds)
            sessionStore?.addSession(WorkSession(
                startTime: start, durationMinutes: totalTime / 60.0,
                type: type, label: currentPhase == .work ? (currentLabel.isEmpty ? nil : currentLabel) : nil,
                breakKinds: kinds
            ))
        }

        elapsedBeforePause = 0
        lastResumeTime = nil
        sessionStartTime = nil
        clearCheckpoint()

        if settings?.soundEnabled ?? true { NSSound(named: "Glass")?.play() }

        if currentPhase == .work {
            let capturedDuration = totalTime   // "Keep Going" reuses the same length
            lastCompletedLabel = currentLabel.isEmpty ? nil : currentLabel
            workSessionsCompleted += 1
            sendNotification(breakStarting: false)

            completionPanel.show(label: lastCompletedLabel) { [weak self] action in
                guard let self else { return }
                switch action {
                case .keepGoing:
                    self.currentPhase = .work
                    self.totalTime = capturedDuration
                    self.timeRemaining = capturedDuration
                    self.updateBlocking()
                    self.start()
                case .takeBreak:
                    self.currentPhase = .shortBreak
                    self.totalTime = self.breakDuration
                    self.timeRemaining = self.breakDuration
                    self.updateBlocking()
                    self.start()
                case .timedOut:
                    // Only auto-start break on timeout if the user has that setting on
                    if self.settings?.autoBreakEnabled ?? false {
                        self.currentPhase = .shortBreak
                        self.totalTime = self.breakDuration
                        self.timeRemaining = self.breakDuration
                        self.updateBlocking()
                        self.start()
                    } else {
                        self.currentPhase = .work
                        self.setTimeForCurrentPhase()
                        self.updateBlocking()
                    }
                }
            }

            // While panel is visible the timer sits idle in work state
            currentPhase = .work
            setTimeForCurrentPhase()
            updateBlocking()
        } else {
            currentBreakKinds = []
            currentPhase = .work
            setTimeForCurrentPhase()
            updateBlocking()
            sendNotification(breakStarting: false)
            handleAutoStart()
        }
    }

    private func setTimeForCurrentPhase() {
        switch currentPhase {
        case .work: totalTime = FocusCategories.isLife(currentLabel) ? FocusCategories.openEndedSeconds : workDuration
        case .shortBreak, .longBreak: totalTime = breakDuration
        }
        timeRemaining = totalTime
    }

    private func handleAutoStart() {
        guard let settings, settings.autoStartWork else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.start() }
    }

    private func unblockIfNeeded() {
        guard isBlockingActive else { return }
        isBlockingActive = false
        DispatchQueue.global(qos: .userInitiated).async { SiteBlocker.unblockAll() }
    }

    // MARK: - Site blocking

    private func observeSettingsChanges() {
        settingsSubscriptions.removeAll()
        guard let settings else { return }

        settings.$blockedSites
            .dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyBlockingIfNeeded() }
            .store(in: &settingsSubscriptions)

        settings.$siteBlockingEnabled
            .dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyBlockingIfNeeded() }
            .store(in: &settingsSubscriptions)

        settings.$blockDuringBreaks
            .dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyBlockingIfNeeded() }
            .store(in: &settingsSubscriptions)
    }

    private func reapplyBlockingIfNeeded() {
        guard isActive else { return }
        if isBlockingActive { isBlockingActive = false }
        updateBlocking()
    }

    /// Shared by the /etc/hosts blocker and the Chrome extension (`BrowserBridge`).
    var shouldBlockSites: Bool {
        guard let settings, settings.siteBlockingEnabled, !settings.blockedSites.isEmpty else { return false }
        return isOnBreak ? (settings.blockDuringBreaks && isActive) : isFocusRunning
    }

    var isFocusRunning: Bool { isActive && !isOnBreak && !FocusCategories.isLife(currentLabel) }

    func updateBlocking() {
        guard let settings else { unblockIfNeeded(); return }
        let shouldBlock = shouldBlockSites
        if shouldBlock && !isBlockingActive {
            isBlockingActive = true
            let domains = settings.blockedSites
            DispatchQueue.global(qos: .userInitiated).async { SiteBlocker.block(domains: domains) }
        } else if !shouldBlock && isBlockingActive {
            unblockIfNeeded()
        }
    }

    // MARK: - Crash-safe partial save

    /// Persist the in-progress local session before any code path that
    /// resets engine state in response to a *remote* idle signal (CK or
    /// Multipeer). Without this guard, a peer launching and broadcasting
    /// idle destroys our accumulated time silently.
    private func savePartialIfActive(reason: String, stoppedStart: Date? = nil, stoppedAt: Date? = nil) {
        guard let store = sessionStore, let start = sessionStartTime else { return }
        guard let end = RemoteStop.savedEnd(mine: start, stoppedStart: stoppedStart, stoppedAt: stoppedAt ?? Date(),
                                            stale: knowledgeStale, shared: SharedSessionMemory.wasShared(start)) else {
            SyncLog.event("skipStaleSegment", ["start": "\(start)", "stoppedStart": SyncLog.opt(stoppedStart), "reason": reason])
            return
        }
        let elapsed = RemoteStop.duration(elapsed: elapsed(until: end), start: start, end: end)
        guard elapsed >= 60 else {
            SyncLog.event("savePartialSkip", [
                "reason": reason,
                "elapsed": elapsed,
                "phase": phaseKey(currentPhase),
            ])
            return
        }
        SyncLog.event("savePartial", [
            "reason": reason,
            "elapsedMin": elapsed / 60.0,
            "phase": phaseKey(currentPhase),
            "label": currentLabel,
            "startTime": start,
            "end": end,
            "stoppedStart": SyncLog.opt(stoppedStart),
        ])
        if currentPhase == .work {
            store.addSession(WorkSession(
                startTime: start, durationMinutes: elapsed / 60.0,
                type: .work, label: currentLabel.isEmpty ? nil : currentLabel
            ))
        } else {
            store.addSession(WorkSession(
                startTime: start, durationMinutes: elapsed / 60.0,
                type: .shortBreak, label: nil,
                breakKinds: currentBreakKinds.isEmpty ? nil : currentBreakKinds
            ))
        }
    }

    // MARK: - Checkpoint

    private func saveCheckpoint() {
        // Persist both work AND break in-progress so a kill-and-relaunch
        // recovers the timer regardless of phase. Previously only work
        // was checkpointed, which meant if Mac was killed during a break,
        // it'd boot showing idle (and the user had no way to resume).
        guard let start = sessionStartTime else { clearCheckpoint(); return }
        var data: [String: Any] = [
            "sessionStartTime": start.timeIntervalSince1970,
            "elapsedBeforePause": elapsedBeforePause,
            "totalTime": totalTime,
            "currentLabel": currentLabel,
            "currentPhase": phaseKey(currentPhase),
            "currentBreakKinds": currentBreakKinds.map(\.rawValue),
        ]
        if let resume = lastResumeTime { data["lastResumeTime"] = resume.timeIntervalSince1970 }
        UserDefaults.standard.set(data, forKey: Self.checkpointKey)
    }

    private func phaseKey(_ p: Phase) -> String {
        switch p {
        case .work: return "work"
        case .shortBreak: return "shortBreak"
        case .longBreak: return "longBreak"
        }
    }

    private func clearCheckpoint() {
        UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
    }

    func saveOnQuit() {
        // Flush checkpoint to disk immediately before the process exits.
        saveCheckpoint()
        UserDefaults.standard.synchronize()
    }

    func recoverPartialSession(into store: SessionStore) {
        guard let data = UserDefaults.standard.dictionary(forKey: Self.checkpointKey) else { return }
        clearCheckpoint()

        guard let startEpoch  = data["sessionStartTime"]    as? Double,
              let elapsed0    = data["elapsedBeforePause"]  as? Double,
              let total       = data["totalTime"]            as? Double else { return }

        // Compute how much time had elapsed, including any dead time while the app was quit.
        var elapsed = elapsed0
        let wasRunning = data["lastResumeTime"] != nil
        if let resumeEpoch = data["lastResumeTime"] as? Double {
            elapsed += Date().timeIntervalSince(Date(timeIntervalSince1970: resumeEpoch))
        }

        let label = (data["currentLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let phaseRaw = data["currentPhase"] as? String ?? "work"
        let restoredPhase: Phase = {
            switch phaseRaw {
            case "shortBreak": return .shortBreak
            case "longBreak":  return .longBreak
            default:           return .work
            }
        }()
        let kindsRaw = (data["currentBreakKinds"] as? [String]) ?? []
        let restoredKinds = kindsRaw.compactMap { BreakKind(rawValue: $0) }
        let remaining = total - elapsed

        // If the session would have finished while the app was dead, save it as completed.
        if elapsed >= total {
            if total >= 60 {
                let sessionType: WorkSession.SessionType = restoredPhase == .work ? .work : .shortBreak
                store.addSession(WorkSession(
                    startTime: Date(timeIntervalSince1970: startEpoch),
                    durationMinutes: total / 60.0, type: sessionType,
                    label: restoredPhase == .work ? label : nil,
                    breakKinds: restoredPhase == .work ? nil : (restoredKinds.isEmpty ? nil : restoredKinds)
                ))
            }
            return
        }

        // Session still has time left — restore the live timer state.
        currentPhase       = restoredPhase
        currentBreakKinds  = restoredKinds
        totalTime          = total
        timeRemaining      = remaining
        elapsedBeforePause = elapsed
        sessionStartTime   = Date(timeIntervalSince1970: startEpoch)
        knowledgeStale = true
        currentLabel       = label ?? ""

        if wasRunning {
            // Auto-resume after a short delay so the UI and settings are fully initialised.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.start()
            }
        }
        // If it was paused before the kill, leave it in the paused state.
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func sendNotification(breakStarting: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Focus"
        content.body = breakStarting
            ? "Session complete — \(Int((settings?.shortBreakMinutes ?? 10)))m break starting."
            : currentPhase == .work
                ? "Break over — ready to focus?"
                : "Session complete."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
