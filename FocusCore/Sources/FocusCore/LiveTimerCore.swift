import Foundation

/// When and on which device the user did something to the timer.
public struct LiveStamp: Codable, Hashable, Comparable, Sendable {
    public var at: Date
    public var device: String

    public init(at: Date, device: String) {
        self.at = at
        self.device = device
    }

    public static func < (a: LiveStamp, b: LiveStamp) -> Bool {
        a.at != b.at ? a.at < b.at : a.device < b.device
    }
}

/// The block a state ended, as the device that ended it knew it.
public struct LiveEnded: Codable, Equatable, Sendable {
    public var id: UUID?
    public var start: Date
    public var end: Date

    public init(id: UUID?, start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// What one device has running, as it tells the others. Never edited once
/// sent: every change is a new state, so iCloud can't splice two devices'
/// writes together (10/29: the Mac's running Class merged with the phone's
/// older stop into "stopped", and the Mac saved 23 hours of Class).
public struct LiveState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, work, breakPhase }

    public var phase: Phase
    /// Stable across pause, resume, relabel and moving the start.
    public var blockID: UUID?
    public var start: Date?
    public var label: String
    public var breakKinds: [BreakKind]
    public var totalSeconds: Double
    /// Seconds left on the clock at `sentAt`.
    public var remainingSeconds: Double
    public var isRunning: Bool
    public var sentAt: Date
    /// The action that began this block (or, idle, the stop).
    public var created: LiveStamp
    /// The latest action on it.
    public var updated: LiveStamp
    /// The block this one replaced, or that this stop ended.
    public var ended: LiveEnded?
    /// From a build that didn't stamp its states: ordered by when it was written.
    public var legacy: Bool

    public init(phase: Phase, blockID: UUID?, start: Date?, label: String, breakKinds: [BreakKind],
                totalSeconds: Double, remainingSeconds: Double, isRunning: Bool, sentAt: Date,
                created: LiveStamp, updated: LiveStamp, ended: LiveEnded?, legacy: Bool = false) {
        self.phase = phase
        self.blockID = blockID
        self.start = start
        self.label = label
        self.breakKinds = breakKinds
        self.totalSeconds = totalSeconds
        self.remainingSeconds = remainingSeconds
        self.isRunning = isRunning
        self.sentAt = sentAt
        self.created = created
        self.updated = updated
        self.ended = ended
        self.legacy = legacy
    }

    public var endTime: Date? { isRunning ? sentAt.addingTimeInterval(remainingSeconds) : nil }

    public func elapsed(at now: Date) -> TimeInterval {
        let base = totalSeconds - remainingSeconds
        return max(0, isRunning ? base + now.timeIntervalSince(sentAt) : base)
    }

    /// Which state wins. Blocks are ordered by the action that began them,
    /// then by the latest change: so a device re-sending what it had (a
    /// relaunch, a peer reconnecting) never beats a newer action, and a stale
    /// device pausing a block that was already replaced doesn't bring it back.
    /// A total order, so every device ends on the same state whatever order
    /// the states reach it in.
    public static func precedes(_ a: LiveState, _ b: LiveState) -> Bool {
        if a.created != b.created { return a.created < b.created }
        let ai = a.blockID?.uuidString ?? "", bi = b.blockID?.uuidString ?? ""
        if ai != bi { return ai < bi }
        return a.updated < b.updated
    }
}

/// Something the device hosting the timer has to do after a change.
public enum LiveEffect: Sendable {
    /// Log a finished block.
    case save(WorkSession)
    /// Tell the other devices.
    case publish(LiveState)
    /// Saved rows in this stretch are now covered by the running block.
    case clear(start: Date, end: Date)
    /// Log this stretch (nil = Break) where nothing is logged.
    case fill(start: Date, end: Date, label: String?)
}

/// The timer's logic, shared by the Mac and the phone and free of clocks,
/// storage and UI so it can be tested: every call takes `now` and returns
/// what to do.
///
/// Who logs a block: the device whose action ended it. A device told by a
/// newer state that its block was replaced logs nothing, unless that state
/// shows its sender never knew the block (it was idle, or behind); then the
/// block is logged here up to where the new state takes over. A block logged
/// twice with different ends keeps the earlier end (`TimeIntegrity`).
public struct LiveTimerCore: Codable, Equatable, Sendable {
    public struct Block: Codable, Equatable, Sendable {
        public var id: UUID
        public var start: Date
        public var isBreak: Bool
        /// The category; for a break, the one it interrupted.
        public var label: String
        public var breakKinds: [BreakKind]
        public var totalTime: TimeInterval
        public var elapsedBeforePause: TimeInterval
        /// Running since; nil while paused.
        public var resumedAt: Date?
        public var ended: LiveEnded?
        /// From a checkpoint or a state of a build before stamping: whether
        /// it was already logged or replaced elsewhere is unknown, so another
        /// device taking over never logs it here (10/24's 22-hour LeetCode was
        /// an iPad's five-day-old block logged up to the Mac's next switch).
        public var uncertain = false

        public var isRunning: Bool { resumedAt != nil }

        public func elapsed(at now: Date) -> TimeInterval {
            elapsedBeforePause + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        }

        public func remaining(at now: Date) -> TimeInterval { totalTime - elapsed(at: now) }
    }

    public var deviceID: String
    public private(set) var block: Block?
    public private(set) var created: LiveStamp?
    public private(set) var updated: LiveStamp?
    /// What the last stop ended; sent with the idle state.
    public private(set) var lastEnded: LiveEnded?

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    public var isActive: Bool { block != nil }

    // MARK: - Local actions

    /// Starts `label` at `at` (no earlier than what's running), logging what
    /// was running up to then.
    public mutating func begin(isBreak: Bool, label: String, kinds: [BreakKind], plannedSeconds: TimeInterval,
                               at requested: Date, now: Date, id: UUID = UUID()) -> [LiveEffect] {
        let date = clamp(requested, now)
        // Nothing running and started earlier: whatever is logged since then
        // is this now, so it isn't counted twice.
        var fx: [LiveEffect] = block == nil && date < now.addingTimeInterval(-1) ? [.clear(start: date, end: now)] : []
        fx += close(at: date)
        open(id: id, start: date, isBreak: isBreak, label: label, kinds: kinds,
             plannedSeconds: plannedSeconds, ended: lastEnded, now: now)
        fx.append(.publish(state(at: now)))
        return fx
    }

    /// Split at `at`: what was running is logged up to then and `label` runs
    /// from then. Under a minute of focus is relabeled instead.
    public mutating func switchTo(_ label: String, at requested: Date, workSeconds: TimeInterval,
                                  now: Date, id: UUID = UUID()) -> [LiveEffect] {
        let date = clamp(requested, now)
        if var b = block, !b.isBreak {
            if label == b.label { return b.isRunning ? [] : resume(now: now) }
            if b.elapsed(at: date) < 60 {
                b.label = label
                if FocusCategories.isLife(label) && !FocusCategories.isOpenEnded(total: b.totalTime) {
                    b.totalTime += FocusCategories.openEndedSeconds
                }
                if !b.isRunning { b.resumedAt = now }
                block = b
                return touched(now)
            }
        }
        return begin(isBreak: false, label: label, kinds: [],
                     plannedSeconds: FocusCategories.isLife(label) ? FocusCategories.openEndedSeconds : workSeconds,
                     at: date, now: now, id: id)
    }

    /// `minutes` 0 counts up.
    public mutating func startBreak(minutes: Double, kinds: [BreakKind] = [], label: String,
                                    at requested: Date, now: Date, id: UUID = UUID()) -> [LiveEffect] {
        if let b = block, b.isBreak, minutes <= 0 { return b.isRunning ? [] : resume(now: now) }
        return begin(isBreak: true, label: block?.label ?? label, kinds: kinds,
                     plannedSeconds: minutes > 0 ? minutes * 60 : FocusCategories.openEndedSeconds,
                     at: requested, now: now, id: id)
    }

    /// Stopping with nothing running here still tells the others: the user
    /// meant whatever is running, wherever it was started.
    public mutating func stop(at requested: Date, now: Date) -> [LiveEffect] {
        var fx = close(at: clamp(requested, now))
        let stamp = LiveStamp(at: now, device: deviceID)
        created = stamp
        updated = stamp
        fx.append(.publish(state(at: now)))
        return fx
    }

    public mutating func pause(now: Date) -> [LiveEffect] {
        guard var b = block, b.isRunning else { return [] }
        b.elapsedBeforePause = b.elapsed(at: now)
        b.resumedAt = nil
        block = b
        return touched(now)
    }

    public mutating func resume(now: Date) -> [LiveEffect] {
        guard var b = block, !b.isRunning else { return [] }
        b.resumedAt = now
        block = b
        return touched(now)
    }

    /// Rename the running block without splitting it. A break becomes that
    /// category from its start.
    public mutating func relabel(_ label: String, workSeconds: TimeInterval, now: Date) -> [LiveEffect] {
        guard var b = block, !label.isEmpty else { return [] }
        if b.isBreak {
            return begin(isBreak: false, label: label, kinds: [],
                         plannedSeconds: FocusCategories.isLife(label) ? FocusCategories.openEndedSeconds : workSeconds,
                         at: b.start, now: now)
        }
        guard label != b.label else { return [] }
        b.label = label
        if FocusCategories.isLife(label) && !FocusCategories.isOpenEnded(total: b.totalTime) {
            b.totalTime += FocusCategories.openEndedSeconds
        }
        block = b
        return touched(now)
    }

    /// The running block started at `to` instead. Earlier: anything logged
    /// in between is now part of it. Later: the time before is left untracked.
    public mutating func moveStart(to requested: Date, now: Date) -> [LiveEffect] {
        guard var b = block else { return [] }
        let to = min(requested, now)
        let delta = to.timeIntervalSince(b.start)
        guard abs(delta) >= 1 else { return [] }
        let old = b.start
        let elapsed = max(0, b.elapsed(at: now) - delta)
        b.start = to
        b.elapsedBeforePause = elapsed
        b.resumedAt = b.isRunning ? now : nil
        if elapsed >= b.totalTime {
            b.totalTime = FocusCategories.recoveryRunway(total: b.totalTime, elapsed: elapsed) ?? b.totalTime
        }
        block = b
        var fx: [LiveEffect] = delta < 0 ? [.clear(start: to, end: old)] : []
        fx += touched(now)
        return fx
    }

    public mutating func adjustDuration(by seconds: TimeInterval, now: Date) -> [LiveEffect] {
        guard var b = block else { return [] }
        b.totalTime = max(60, b.totalTime + seconds)
        block = b
        return touched(now)
    }

    /// Hand [from, to) of the running block to `label` (nil = Break): the
    /// block is logged up to `from`, the stretch is filled, and the same
    /// category carries on from `to`.
    public mutating func carveOut(from: Date, to: Date, as label: String?, workSeconds: TimeInterval,
                                  now: Date) -> [LiveEffect] {
        guard let b = block, b.isRunning, from >= b.start else { return [] }
        let end = min(to, now)
        guard end.timeIntervalSince(from) >= 60 else { return [] }
        var fx = close(at: from)
        fx.append(.fill(start: from, end: end, label: label))
        let openEnded = b.isBreak || FocusCategories.isLife(b.label)
        open(id: UUID(), start: end, isBreak: b.isBreak, label: b.label, kinds: b.breakKinds,
             plannedSeconds: openEnded ? FocusCategories.openEndedSeconds : workSeconds,
             ended: lastEnded, now: now)
        fx.append(.publish(state(at: now)))
        return fx
    }

    /// Nothing ends on its own: a finished countdown rolls into overtime.
    /// Local only; the others work it out from the same numbers. True when
    /// a countdown just finished (chime).
    public mutating func extendIfNeeded(now: Date) -> Bool {
        guard var b = block, b.isRunning, b.remaining(at: now) <= 0 else { return false }
        let wasCountdown = !FocusCategories.isOpenEnded(total: b.totalTime)
        while b.remaining(at: now) <= 0 { b.totalTime += FocusCategories.openEndedSeconds }
        block = b
        return wasCountdown
    }

    // MARK: - Other devices

    /// Apply another device's state. nil when it's older than what's here
    /// (the caller may send ours back so it catches up). Otherwise it's taken,
    /// after logging our block if that state shows nobody else will.
    public mutating func reconcile(_ incoming: LiveState, now: Date) -> [LiveEffect]? {
        if let mine = currentState(at: now), !LiveState.precedes(mine, incoming) { return nil }
        if incoming.legacy, let theirs = incoming.start, incoming.phase != .idle,
           let ref = block?.start ?? lastEnded?.start, theirs < ref.addingTimeInterval(-3) {
            // An old build re-announcing a block from before ours.
            return nil
        }
        if incoming.legacy, block == nil, incoming.phase != .idle, let theirs = incoming.start,
           let ended = lastEnded?.start, abs(theirs.timeIntervalSince(ended)) <= 3 {
            // An old build announcing the block we ended as still running (10/16).
            return nil
        }
        var fx: [LiveEffect] = []
        if let b = block, !Self.same(b, incoming), let s = Self.unclaimed(b, by: incoming, now: now) {
            fx.append(.save(s))
        }
        adopt(incoming, now: now)
        return fx
    }

    /// Apply every state newer than ours, oldest first, so each handover is
    /// judged against the block it actually replaced.
    public mutating func catchUp(_ states: [LiveState], now: Date) -> [LiveEffect] {
        let mine = currentState(at: now)
        var fx: [LiveEffect] = []
        for s in states.filter({ mine == nil || LiveState.precedes(mine!, $0) }).sorted(by: LiveState.precedes) {
            fx += reconcile(s, now: now) ?? []
        }
        return fx
    }

    /// What this device would tell the others now, or nil before it has
    /// done or heard anything.
    public func currentState(at now: Date) -> LiveState? {
        guard let created, let updated else { return nil }
        if let b = block {
            return LiveState(phase: b.isBreak ? .breakPhase : .work, blockID: b.id, start: b.start, label: b.label,
                             breakKinds: b.breakKinds, totalSeconds: b.totalTime, remainingSeconds: b.remaining(at: now),
                             isRunning: b.isRunning, sentAt: now, created: created, updated: updated, ended: b.ended)
        }
        return LiveState(phase: .idle, blockID: nil, start: lastEnded?.start, label: "", breakKinds: [],
                         totalSeconds: 0, remainingSeconds: 0, isRunning: false, sentAt: now,
                         created: created, updated: updated, ended: lastEnded)
    }

    /// Bring back a block from a checkpoint written by a build before this
    /// one. Stamped with its start, so anything newer elsewhere wins.
    public mutating func restoreLegacy(start: Date, elapsedBeforePause: TimeInterval, totalTime: TimeInterval,
                                       label: String, isBreak: Bool, kinds: [BreakKind], wasRunning: Bool,
                                       now: Date) {
        let elapsed = elapsedBeforePause
        let total = FocusCategories.recoveryRunway(total: totalTime, elapsed: elapsed) ?? totalTime
        block = Block(id: Self.legacyID(start), start: start, isBreak: isBreak, label: label, breakKinds: kinds,
                      totalTime: total, elapsedBeforePause: elapsed, resumedAt: wasRunning ? now : nil, ended: nil,
                      uncertain: true)
        let stamp = LiveStamp(at: start, device: deviceID)
        created = stamp
        updated = stamp
    }

    // MARK: - Private

    private func clamp(_ requested: Date, _ now: Date) -> Date {
        var date = min(requested, now)
        if let b = block { date = max(date, b.start) }
        return date
    }

    private mutating func touched(_ now: Date) -> [LiveEffect] {
        block?.uncertain = false
        updated = LiveStamp(at: now, device: deviceID)
        return [.publish(state(at: now))]
    }

    private func state(at now: Date) -> LiveState { currentState(at: now)! }

    /// Ends the running block at `date`, logging it if it's a minute or more.
    private mutating func close(at date: Date) -> [LiveEffect] {
        guard let b = block else { return [] }
        block = nil
        lastEnded = LiveEnded(id: b.id, start: b.start, end: date)
        return Self.segment(b, until: date).map { [.save($0)] } ?? []
    }

    private mutating func open(id: UUID, start: Date, isBreak: Bool, label: String, kinds: [BreakKind],
                               plannedSeconds: TimeInterval, ended: LiveEnded?, now: Date) {
        let lead = max(0, now.timeIntervalSince(start))
        let total = FocusCategories.recoveryRunway(total: plannedSeconds, elapsed: lead) ?? plannedSeconds
        block = Block(id: id, start: start, isBreak: isBreak, label: label, breakKinds: kinds, totalTime: total,
                      elapsedBeforePause: lead, resumedAt: now, ended: ended)
        let stamp = LiveStamp(at: now, device: deviceID)
        created = stamp
        updated = stamp
    }

    private mutating func adopt(_ s: LiveState, now: Date) {
        created = s.created
        updated = s.updated
        guard s.phase != .idle else {
            block = nil
            lastEnded = s.ended
            return
        }
        lastEnded = s.ended ?? lastEnded
        let elapsed = s.elapsed(at: now)
        var total = s.totalSeconds
        if elapsed >= total { total = FocusCategories.recoveryRunway(total: total, elapsed: elapsed) ?? total }
        block = Block(id: s.blockID ?? Self.legacyID(s.start ?? now), start: s.start ?? now, isBreak: s.phase == .breakPhase,
                      label: s.label, breakKinds: s.breakKinds, totalTime: total, elapsedBeforePause: elapsed,
                      resumedAt: s.isRunning ? now : nil, ended: s.ended, uncertain: s.legacy)
    }

    static func same(_ b: Block, _ s: LiveState) -> Bool {
        guard s.phase != .idle else { return false }
        if let id = s.blockID { return id == b.id }
        guard let start = s.start else { return false }
        return abs(start.timeIntervalSince(b.start)) <= 3
    }

    /// Our block, if `s` takes over from it without its sender having logged
    /// it: the sender was idle or holding an older block when it acted.
    static func unclaimed(_ b: Block, by s: LiveState, now: Date) -> WorkSession? {
        // Old builds log their own handovers; and with them, or with a block
        // of unknown history here, a gap beats a guess.
        if b.uncertain || s.legacy { return nil }
        if let e = s.ended {
            if let id = e.id {
                if id == b.id { return nil }
            } else if abs(e.start.timeIntervalSince(b.start)) <= 3 {
                return nil
            }
            // It ended a block that began after ours: ours was replaced by a
            // change we never saw, and whoever made it logged ours.
            if e.start > b.start.addingTimeInterval(3) { return nil }
        }
        // A stop from a device that didn't know our block stops it when they
        // pressed it; a new block takes over from its start.
        let cutoff = s.phase == .idle ? s.updated.at : (s.start ?? s.updated.at)
        return segment(b, until: min(max(cutoff, b.start), now))
    }

    /// Old builds send no block ids: devices adopting the same one agree on it.
    static func legacyID(_ start: Date) -> UUID {
        let seconds = UInt64(max(0, start.timeIntervalSince1970.rounded()))
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", seconds))!
    }

    static func segment(_ b: Block, until end: Date) -> WorkSession? {
        let seconds = RemoteStop.duration(elapsed: b.elapsed(at: end), start: b.start, end: end)
        guard seconds >= 60 else { return nil }
        return WorkSession(startTime: b.start, durationMinutes: seconds / 60,
                           type: b.isBreak ? .shortBreak : .work,
                           label: b.isBreak ? nil : (b.label.isEmpty ? nil : b.label),
                           breakKinds: b.isBreak ? (b.breakKinds.isEmpty ? nil : b.breakKinds) : nil)
    }
}
