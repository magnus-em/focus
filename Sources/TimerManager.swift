import Foundation
import FocusCore
import Combine
import UserNotifications
import AppKit

/// Fires on every tick. Only the views that show the running clock observe
/// it, so the rest of the popover doesn't re-render twice a second.
final class TimerClock: ObservableObject {}

/// The Mac's timer: `LiveTimerCore` (the logic, shared with the phone) plus
/// the clock, site blocking, the completion panel, pause grace and the two
/// ways of reaching the other devices.
class TimerManager: ObservableObject {
    let clock = TimerClock()
    private var remaining: TimeInterval
    var timeRemaining: TimeInterval {
        get { remaining }
        set {
            objectWillChange.send()
            clock.objectWillChange.send()
            remaining = newValue
        }
    }
    @Published var totalTime: TimeInterval
    @Published var isRunning = false
    @Published var currentPhase: Phase = .work
    @Published var workSessionsCompleted: Int = 0
    @Published var isBlockingActive = false

    @Published var currentLabel: String = "" {
        didSet { if !isActive && currentLabel != oldValue { setIdleTime() } }
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
    @Published private(set) var sessionStartTime: Date?
    private var core = LiveTimerCore(deviceID: TimerStateSync.persistedDeviceID())
    private var settingsSubscriptions = Set<AnyCancellable>()
    private let completionPanel = CompletionPanel()
    private var tickCount = 0
    private static let legacyCheckpointKey = "timerCheckpoint"

    var sessionStore: SessionStore?
    /// Fired after a command from another device (phone Shortcut, etc.) is applied.
    var onCommandApplied: ((TimerCommand) -> Void)?
    /// Fired when a focus segment is saved because the user switched, stopped
    /// or took a break (not on auto-finalize or crash recovery).
    var onFocusSegmentSaved: ((WorkSession) -> Void)?
    var settings: AppSettings? {
        didSet {
            observeSettingsChanges()
            updateBlocking()
        }
    }

    /// Cross-device live-timer sync. Set externally after init.
    var stateSync: TimerStateSync? {
        didSet {
            guard let stateSync else { return }
            core.deviceID = stateSync.deviceID
            stateSync.onStatesChanged = { [weak self] states in self?.catchUp(states) }
            stateSync.onCommands = { [weak self] cmds in
                guard let self else { return }
                for c in cmds { self.apply(c) }
                if let last = cmds.last { self.onCommandApplied?(last) }
            }
            // Whatever happened elsewhere while Focus was closed. Nothing is
            // announced on resume: the restored state keeps its old stamp, so
            // it can't beat anything newer (10/29: reopened after a day, the
            // Mac re-sent Class from 9:25 the morning before as new).
            catchUp(stateSync.allStates())
            if let s = core.currentState(at: Date()), !stateSync.contains(s) { stateSync.publish(s) }
        }
    }
    var localBroadcast: LocalTimerBroadcast? {
        didSet {
            localBroadcast?.onMessage = { [weak self] msg in self?.receive(msg) }
            // A peer that just connected may have missed a start or a stop.
            localBroadcast?.onPeerConnected = { [weak self] in self?.sendCurrent() }
        }
    }

    private var workDuration: TimeInterval { (settings?.workMinutes ?? 25) * 60 }

    init() {
        self.totalTime = 25 * 60
        self.remaining = 25 * 60
        requestNotificationPermission()
    }

    func applySettings() {
        guard !isActive else { return }
        setIdleTime()
    }

    // MARK: - Display

    var progress: Double { FocusCategories.progress(total: totalTime, remaining: timeRemaining) }

    var timeString: String { FocusCategories.timeString(total: totalTime, remaining: timeRemaining) }

    var isActive: Bool { core.isActive }
    var isOnBreak: Bool { currentPhase != .work }

    var menuBarTimeText: String {
        isRunning ? timeString : "⏸ \(timeString)"
    }

    var currentElapsedSeconds: TimeInterval { core.block?.elapsed(at: Date()) ?? 0 }

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
        cancelPauseGrace()
        perform("start") { core, now in
            if core.block != nil { return core.resume(now: now) }
            return core.begin(isBreak: false, label: currentLabel, kinds: [], plannedSeconds: totalTime, at: now, now: now)
        }
    }

    func pause() {
        perform("pause") { core, now in core.pause(now: now) }
        if currentPhase == .work && sessionStartTime != nil && !isRunning { startPauseGrace() }
    }

    /// Rename the running block without splitting it (undo of a screen
    /// auto-switch). Focus ↔ focus only, so the countdown stays as it is.
    func relabelRunning(_ label: String) {
        guard isActive, currentPhase == .work, label != currentLabel else { return }
        perform("relabel \(label)") { core, now in core.relabel(label, workSeconds: workDuration, now: now) }
    }

    /// Split the timeline at `date`: whatever was running is saved up to
    /// then, and focus on `label` runs from then. A focus segment under a
    /// minute is relabeled rather than saved.
    func switchTo(_ label: String, at requested: Date = Date()) {
        AwayPanel.dismissAll()
        cancelPauseGrace()
        perform("switch \(label)", notify: true) { core, now in
            core.switchTo(label, at: requested, workSeconds: workDuration, now: now)
        }
    }

    /// Hand [from, to) of the running block to `label` (nil = break): the
    /// block is saved up to `from`, the span is logged, and the same
    /// category carries on from `to`.
    func carveOut(from: Date, to: Date, as label: String?) {
        cancelPauseGrace()
        perform("carveOut") { core, now in
            core.carveOut(from: from, to: to, as: label, workSeconds: workDuration, now: now)
        }
    }

    func stop(at date: Date) {
        AwayPanel.dismissAll()
        cancelPauseGrace()
        perform("stop", notify: true) { core, now in core.stop(at: date, now: now) }
    }

    func apply(_ command: TimerCommand) {
        perform("command \(command.action.rawValue)", notify: true) { core, now in
            switch command.action {
            case .switchTo:
                guard !command.label.isEmpty else { return [] }
                return core.switchTo(command.label, at: command.createdAt, workSeconds: workDuration,
                                     now: now, id: command.id)
            case .stop:
                return core.stop(at: command.createdAt, now: now)
            case .startBreak:
                return core.startBreak(minutes: command.minutes, label: currentLabel, at: command.createdAt,
                                       now: now, id: command.id)
            }
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
        perform("skip") { core, now in core.stop(at: now, now: now) }
    }

    func startManualBreak(minutes: Double, kinds: [BreakKind] = [], at requested: Date = Date()) {
        AwayPanel.dismissAll()
        cancelPauseGrace()
        perform("break", notify: true) { core, now in
            core.startBreak(minutes: minutes, kinds: kinds, label: currentLabel, at: requested, now: now)
        }
    }

    func adjustDuration(by minutes: Double) {
        perform("adjust") { core, now in core.adjustDuration(by: minutes * 60, now: now) }
    }

    func setSessionDuration(_ minutes: Double) {
        guard !isActive else { return }
        totalTime = minutes * 60
        timeRemaining = minutes * 60
    }

    // MARK: - Core

    /// Catch up with what's stored first, so an action is never taken on a
    /// block another device already replaced. `notify`: focus segments this
    /// logs count as finished blocks (the recall prompt).
    private func perform(_ what: String, notify: Bool = false,
                         _ body: (inout LiveTimerCore, Date) -> [LiveEffect]) {
        let now = Date()
        let fx = core.catchUp(stateSync?.allStates() ?? [], now: now)
        if core.extendIfNeeded(now: now) { countdownFinished() }
        let local = body(&core, now)
        SyncLog.event("liveAction", ["what": what])
        run(fx, notify: false)
        run(local, notify: notify)
    }

    private func catchUp(_ states: [LiveState]) {
        let now = Date()
        let before = core.currentState(at: now)
        let fx = core.catchUp(states, now: now)
        guard let after = core.currentState(at: now), before.map({ !Self.same($0, after) }) ?? true else { return }
        SyncLog.event("liveAdopt", TimerStateSync.describe(after))
        run(fx, notify: false)
    }

    private func receive(_ msg: LocalTimerBroadcast.Message) {
        guard let s = msg.state else { return }
        let now = Date()
        if let fx = core.reconcile(s, now: now) {
            SyncLog.event("liveAdoptMp", TimerStateSync.describe(s))
            run(fx, notify: false)
        } else if let mine = core.currentState(at: now), LiveState.precedes(s, mine), let id = stateSync?.deviceID {
            // It's behind: send it ours.
            localBroadcast?.send(.init(deviceID: id, live: mine))
        }
    }

    private func sendCurrent() {
        guard let s = core.currentState(at: Date()), let id = stateSync?.deviceID else { return }
        localBroadcast?.send(.init(deviceID: id, live: s))
    }

    private static func same(_ a: LiveState, _ b: LiveState) -> Bool {
        !LiveState.precedes(a, b) && !LiveState.precedes(b, a)
    }

    private func run(_ fx: [LiveEffect], notify: Bool) {
        for e in fx {
            switch e {
            case .save(let s):
                sessionStore?.addSession(s)
                if notify, s.type == .work { onFocusSegmentSaved?(s) }
            case .publish(let s):
                if let id = stateSync?.deviceID { localBroadcast?.send(.init(deviceID: id, live: s)) }
                stateSync?.publish(s)
            case .clear(let start, let end):
                sessionStore?.clear(start: start, end: end)
            case .fill(let start, let end, let label):
                sessionStore?.fill(start: start, end: end, label: label)
            }
        }
        LiveCheckpoint.save(core)
        mirror()
    }

    /// Copies the core's block into the published properties.
    private func mirror() {
        let now = Date()
        if let b = core.block {
            currentPhase = b.isBreak ? .shortBreak : .work
            if currentLabel != b.label { currentLabel = b.label }
            currentBreakKinds = b.breakKinds
            totalTime = b.totalTime
            timeRemaining = max(0, b.remaining(at: now))
            if sessionStartTime != b.start { sessionStartTime = b.start }
            isRunning = b.isRunning
        } else {
            let wasActive = sessionStartTime != nil
            currentPhase = .work
            currentBreakKinds = []
            if sessionStartTime != nil { sessionStartTime = nil }
            isRunning = false
            if wasActive { setIdleTime() }
        }
        if pauseStartedAt != nil && (isRunning || core.block == nil || currentPhase != .work) { cancelPauseGrace() }
        if isRunning, timer == nil {
            tickCount = 0
            timer = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
        } else if !isRunning {
            timer?.cancel()
            timer = nil
        }
        updateBlocking()
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
        guard let b = core.block, !b.isRunning, !b.isBreak else { return }
        perform("pauseGrace") { core, now in core.stop(at: now, now: now) }
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
        if core.extendIfNeeded(now: now) {
            LiveCheckpoint.save(core)
            countdownFinished()
        }
        guard let b = core.block else { return }
        clock.objectWillChange.send()
        if totalTime != b.totalTime { totalTime = b.totalTime }
        remaining = max(0, b.remaining(at: now))
        tickCount += 1
        // Live day totals elsewhere read the running block; refreshing them
        // every 30s is plenty.
        if tickCount % 60 == 0 { objectWillChange.send() }
    }

    /// Nothing ends on its own: a finished countdown rolls into overtime and
    /// keeps tracking until the user switches or stops.
    private func countdownFinished() {
        guard let b = core.block else { return }
        totalTime = b.totalTime
        if settings?.soundEnabled ?? true { NSSound(named: "Glass")?.play() }
        if !b.isBreak {
            workSessionsCompleted += 1
            lastCompletedLabel = b.label.isEmpty ? nil : b.label
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

    private func setIdleTime() {
        totalTime = FocusCategories.isLife(currentLabel) ? FocusCategories.openEndedSeconds : workDuration
        timeRemaining = totalTime
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
        return isOnBreak ? (settings.blockDuringBreaks && isActive)
            : isFocusRunning && !FocusCategories.neverBlocks.contains(currentLabel)
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

    // MARK: - Checkpoint

    func saveOnQuit() {
        LiveCheckpoint.save(core)
        UserDefaults.standard.synchronize()
    }

    /// Brings back what was running when Focus last quit or crashed. Elapsed
    /// time includes the time it was closed, as if it had kept running.
    func recoverPartialSession(into store: SessionStore) {
        if let saved = LiveCheckpoint.load() {
            core = saved
        } else if let data = UserDefaults.standard.dictionary(forKey: Self.legacyCheckpointKey),
                  let startEpoch = data["sessionStartTime"] as? Double,
                  let elapsed0 = data["elapsedBeforePause"] as? Double,
                  let total = data["totalTime"] as? Double {
            let now = Date()
            let resume = (data["lastResumeTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let isBreak = (data["currentPhase"] as? String ?? "work") != "work"
            core.restoreLegacy(start: Date(timeIntervalSince1970: startEpoch),
                               elapsedBeforePause: elapsed0 + (resume.map { now.timeIntervalSince($0) } ?? 0),
                               totalTime: total, label: data["currentLabel"] as? String ?? "", isBreak: isBreak,
                               kinds: ((data["currentBreakKinds"] as? [String]) ?? []).compactMap(BreakKind.init(rawValue:)),
                               wasRunning: resume != nil, now: now)
            LiveCheckpoint.save(core)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyCheckpointKey)
        core.deviceID = TimerStateSync.persistedDeviceID()
        _ = core.extendIfNeeded(now: Date())
        mirror()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}
