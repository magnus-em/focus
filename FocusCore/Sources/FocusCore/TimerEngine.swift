import Foundation
import SwiftData
import Combine
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

/// The iPhone/iPad timer: `LiveTimerCore` (the logic, shared with the Mac)
/// plus the clock, the store, notifications and the two ways of reaching the
/// other devices. The engine owns no UI.
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

    /// The category: what's running, or what starts next. Sticky across stops.
    @Published public var currentLabel: String = ""
    @Published public private(set) var currentBreakKinds: [BreakKind] = []
    @Published public private(set) var lastCompletedLabel: String? = nil
    @Published public private(set) var workSessionsCompletedToday: Int = 0

    /// Live elapsed seconds for the current session — even while paused.
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var sessionStartTime: Date?

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
    /// The main context, so inserts show in `@Query` views right away.
    private var context: ModelContext { container.mainContext }
    private var ticker: AnyCancellable?
    public let stateSync: TimerStateSync
    public let localBroadcast: LocalTimerBroadcast
    private var core: LiveTimerCore
    /// Countdown for the next start from idle (a preset chip).
    private var idleTotal: TimeInterval
    private static let legacyCheckpointKey = "focusTimerEngineCheckpoint"

    // MARK: - Init

    public init(container: ModelContainer, settings: Settings = .init()) {
        self.container = container
        self.settings = settings
        self.idleTotal = settings.workMinutes * 60
        self.totalTime = settings.workMinutes * 60
        self.timeRemaining = settings.workMinutes * 60
        self.stateSync = TimerStateSync(container: container)
        self.localBroadcast = LocalTimerBroadcast(deviceID: stateSync.deviceID)
        self.core = LiveCheckpoint.load() ?? LiveTimerCore(deviceID: stateSync.deviceID)
        core.deviceID = stateSync.deviceID
        restoreLegacyCheckpoint()
        recomputeTodayCount()
        requestNotificationPermission()

        stateSync.onStatesChanged = { [weak self] states in self?.catchUp(states) }
        stateSync.onCommands = { [weak self] cmds in
            for c in cmds { self?.apply(c) }
        }
        localBroadcast.onMessage = { [weak self] msg in self?.receive(msg) }
        // A peer that just connected may have missed a start or a stop.
        localBroadcast.onPeerConnected = { [weak self] in self?.sendCurrent() }

        // Whatever happened elsewhere while this app wasn't running. Nothing
        // is announced on resume: the restored state keeps its old stamp, so
        // it can't beat anything newer (10/24: an iPad back after five days
        // re-announced its LeetCode block as new).
        catchUp(stateSync.allStates())
        if let s = core.currentState(at: Date()), !stateSync.contains(s) { stateSync.publish(s) }
        mirror(reschedule: true)

        #if canImport(UIKit)
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
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Schedule a local notification at the expected completion moment so the
    /// user hears the bell even if the app is backgrounded or the screen is off.
    private func scheduleCompletionNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notifIdentifier])
        guard isRunning, timeRemaining > 1, !FocusCategories.isOpenEnded(total: totalTime) else { return }
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
        center.removePendingNotificationRequests(withIdentifiers: [Self.notifIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notifIdentifier])
    }

    // MARK: - Computed

    public var isActive: Bool { core.isActive }
    public var isOnBreak: Bool { phase.isBreak }

    public var progress: Double { FocusCategories.progress(total: totalTime, remaining: timeRemaining) }

    public var timeString: String { FocusCategories.timeString(total: totalTime, remaining: timeRemaining) }

    /// Active time in the current session so far, pauses excluded; read-only
    /// for intents (Siri's daily total).
    public var activeElapsedSeconds: TimeInterval { core.block?.elapsed(at: Date()) ?? 0 }

    // MARK: - Public controls

    public func start() {
        perform("start") { core, now in
            if core.block != nil { return core.resume(now: now) }
            let life = FocusCategories.isLife(currentLabel)
            return core.begin(isBreak: false, label: currentLabel, kinds: [],
                              plannedSeconds: life ? FocusCategories.openEndedSeconds : idleTotal, at: now, now: now)
        }
    }

    public func pause() {
        perform("pause") { core, now in core.pause(now: now) }
    }

    public func toggleRunPause() {
        if isRunning { pause() } else { start() }
    }

    /// Split the timeline at `date`: what was running is saved up to then and
    /// `label` runs from then. Under a minute of focus is relabeled.
    public func switchTo(_ label: String, at requested: Date = Date()) {
        perform("switch \(label)") { core, now in
            core.switchTo(label, at: requested, workSeconds: settings.workMinutes * 60, now: now)
        }
    }

    public func stop(at requested: Date) {
        perform("stop") { core, now in core.stop(at: requested, now: now) }
    }

    /// Stop the timer. Saves partial work if ≥ 1 minute elapsed.
    public func stop() { stop(at: Date()) }

    public func skip() { stop() }

    public func startBreak(minutes: Double, kinds: [BreakKind] = [], at requested: Date = Date()) {
        perform("break") { core, now in
            core.startBreak(minutes: minutes, kinds: kinds, label: currentLabel, at: requested, now: now)
        }
    }

    /// Take-a-break from idle (or interrupting work).
    public func startManualBreak(minutes: Double, kinds: [BreakKind] = []) {
        startBreak(minutes: minutes, kinds: kinds)
    }

    /// The running block started at `date` instead. Earlier takes over what's
    /// logged in between; later leaves the time before it untracked.
    public func moveStart(to date: Date) {
        perform("moveStart") { core, now in core.moveStart(to: date, now: now) }
    }

    /// [from, to) of the running block becomes `label` (nil = Break); the
    /// block carries on from `to`.
    public func carveOut(from: Date, to: Date, as label: String?) {
        perform("carveOut") { core, now in
            core.carveOut(from: from, to: to, as: label, workSeconds: settings.workMinutes * 60, now: now)
        }
    }

    /// Rename the running block from its start, without splitting it.
    public func relabel(_ label: String) {
        perform("relabel \(label)") { core, now in
            core.relabel(label, workSeconds: settings.workMinutes * 60, now: now)
        }
    }

    public func apply(_ command: TimerCommand) {
        perform("command \(command.action.rawValue)") { core, now in
            switch command.action {
            case .switchTo:
                guard !command.label.isEmpty else { return [] }
                return core.switchTo(command.label, at: command.createdAt, workSeconds: settings.workMinutes * 60,
                                     now: now, id: command.id)
            case .stop:
                return core.stop(at: command.createdAt, now: now)
            case .startBreak:
                return core.startBreak(minutes: command.minutes, label: currentLabel, at: command.createdAt,
                                       now: now, id: command.id)
            }
        }
    }

    /// Quick presets while idle (15 / 25 / 45 / 60 min etc.).
    public func setSessionDuration(_ minutes: Double) {
        guard !isActive else { return }
        idleTotal = minutes * 60
        mirror(reschedule: false)
    }

    /// Mid-session ±N minute nudge.
    public func adjustDuration(by minutes: Double) {
        perform("adjust") { core, now in core.adjustDuration(by: minutes * 60, now: now) }
    }

    // MARK: - Machinery

    /// Catch up with what's stored first, so an action is never taken on a
    /// block another device already replaced.
    private func perform(_ what: String, _ body: (inout LiveTimerCore, Date) -> [LiveEffect]) {
        let now = Date()
        var fx = core.catchUp(stateSync.allStates(), now: now)
        if core.extendIfNeeded(now: now) { countdownFinished() }
        fx += body(&core, now)
        SyncLog.event("liveAction", ["what": what])
        run(fx)
    }

    private func catchUp(_ states: [LiveState]) {
        let now = Date()
        let before = core.currentState(at: now)
        let fx = core.catchUp(states, now: now)
        guard let after = core.currentState(at: now), before.map({ !Self.same($0, after) }) ?? true else { return }
        SyncLog.event("liveAdopt", TimerStateSync.describe(after))
        run(fx)
    }

    private func receive(_ msg: LocalTimerBroadcast.Message) {
        guard let s = msg.state else { return }
        let now = Date()
        if let fx = core.reconcile(s, now: now) {
            SyncLog.event("liveAdoptMp", TimerStateSync.describe(s))
            run(fx)
        } else if let mine = core.currentState(at: now), LiveState.precedes(s, mine) {
            // It's behind: send it ours.
            localBroadcast.send(.init(deviceID: stateSync.deviceID, live: mine))
        }
    }

    private func sendCurrent() {
        guard let s = core.currentState(at: Date()) else { return }
        localBroadcast.send(.init(deviceID: stateSync.deviceID, live: s))
    }

    private func run(_ fx: [LiveEffect]) {
        for e in fx {
            switch e {
            case .save(let s):
                insertSession(s)
            case .publish(let s):
                localBroadcast.send(.init(deviceID: stateSync.deviceID, live: s))
                stateSync.publish(s)
            case .clear(let start, let end):
                try? context.save()
                _ = LogEdit.paint(start: start, end: end, label: nil, fill: false, in: context)
            case .fill(let start, let end, let label):
                try? context.save()
                _ = LogEdit.paint(start: start, end: end, label: label, in: context)
            }
        }
        LiveCheckpoint.save(core)
        mirror(reschedule: true)
    }

    private static func same(_ a: LiveState, _ b: LiveState) -> Bool {
        !LiveState.precedes(a, b) && !LiveState.precedes(b, a)
    }

    /// Copies the core's block into the published properties.
    private func mirror(reschedule: Bool) {
        let now = Date()
        if let b = core.block {
            phase = b.isBreak ? .breakPhase : .work
            currentLabel = b.label
            currentBreakKinds = b.breakKinds
            totalTime = b.totalTime
            timeRemaining = max(0, b.remaining(at: now))
            elapsedSeconds = b.elapsed(at: now)
            sessionStartTime = b.start
            isRunning = b.isRunning
        } else {
            phase = .work
            currentBreakKinds = []
            totalTime = idleTotal
            timeRemaining = idleTotal
            elapsedSeconds = 0
            sessionStartTime = nil
            isRunning = false
        }
        if isRunning, ticker == nil {
            ticker = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.tick() }
        } else if !isRunning {
            ticker?.cancel()
            ticker = nil
        }
        if reschedule {
            if isRunning { scheduleCompletionNotification() } else { cancelCompletionNotification() }
        }
    }

    private func tick() {
        let now = Date()
        if core.extendIfNeeded(now: now) {
            countdownFinished()
            LiveCheckpoint.save(core)
        }
        guard let b = core.block else { return }
        totalTime = b.totalTime
        timeRemaining = max(0, b.remaining(at: now))
        elapsedSeconds = b.elapsed(at: now)
    }

    /// Nothing ends on its own: a finished countdown rolls into overtime and
    /// keeps tracking. The completion notification already fired on schedule.
    private func countdownFinished() {
        guard let b = core.block, !b.isBreak else { return }
        lastCompletedLabel = b.label.isEmpty ? nil : b.label
        workSessionsCompletedToday += 1
    }

    private func applySettingsIfIdle() {
        guard !isActive else { return }
        idleTotal = settings.workMinutes * 60
        mirror(reschedule: false)
    }

    /// One block logged twice (here and on a peer) keeps the earlier end:
    /// the device that ended it first knew.
    private func insertSession(_ s: WorkSession) {
        let ctx = context
        let lower = s.startTime.addingTimeInterval(-3)
        let upper = s.startTime.addingTimeInterval(3)
        let descriptor = FetchDescriptor<StoredWorkSession>(
            predicate: #Predicate { $0.startTime >= lower && $0.startTime <= upper }
        )
        let nearby = (try? ctx.fetch(descriptor)) ?? []
        let duration = min(s.durationMinutes, max(0, Date().timeIntervalSince(s.startTime)) / 60)
        if let dupe = TimeIntegrity.sameBlock(as: s, in: nearby.map(\.asValue)),
           let row = nearby.first(where: { $0.id == dupe.id }) {
            if duration < row.durationMinutes { row.durationMinutes = duration }
        } else {
            let row = StoredWorkSession(value: s)
            row.durationMinutes = duration
            ctx.insert(row)
        }
        try? ctx.save()
        SyncLog.event("liveSave", ["label": s.label ?? "Break", "start": s.startTime, "minutes": duration])
        if s.type == .work { recomputeTodayCount() }
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

    /// A checkpoint from the build before `LiveTimerCore`.
    private func restoreLegacyCheckpoint() {
        let d = UserDefaults.standard
        guard let data = d.dictionary(forKey: Self.legacyCheckpointKey) else { return }
        d.removeObject(forKey: Self.legacyCheckpointKey)
        guard core.block == nil, core.currentState(at: Date()) == nil,
              let startEpoch = data["sessionStartTime"] as? Double,
              let elapsed0 = data["elapsedBeforePause"] as? Double,
              let total = data["totalTime"] as? Double else { return }
        let now = Date()
        let resume = (data["lastResumeTime"] as? Double).map { Date(timeIntervalSince1970: $0) }
        core.restoreLegacy(start: Date(timeIntervalSince1970: startEpoch),
                           elapsedBeforePause: elapsed0 + (resume.map { now.timeIntervalSince($0) } ?? 0),
                           totalTime: total, label: data["currentLabel"] as? String ?? "", isBreak: false,
                           kinds: [], wasRunning: resume != nil, now: now)
        LiveCheckpoint.save(core)
    }

    private func didBecomeActive() {
        stateSync.pokeForRemote()
        // Push-driven imports can land a moment after coming to the front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.stateSync.pokeForRemote()
        }
        tick()
        if !isRunning { cancelCompletionNotification() }
        recomputeTodayCount()
    }
}
