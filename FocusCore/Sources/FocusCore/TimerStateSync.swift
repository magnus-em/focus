import Foundation
import SwiftData
import Combine

/// The timer states every device has published, through the CloudKit-backed
/// store. Each publish inserts a new `StoredTimerState` row and none is ever
/// edited: a single shared row edited by two devices came back from iCloud
/// as a mix of both (10/29: the Mac's running Class plus the phone's older
/// stop read as "stopped", and the Mac logged 23 hours of Class). Which
/// state wins is `LiveState.precedes`; applying them is `LiveTimerCore.catchUp`.
///
/// Latency: typically 5-30 seconds through iCloud; `LocalTimerBroadcast`
/// covers devices on the same network instantly.
/// Caller must invoke methods from the main thread (mainContext requires it).
public final class TimerStateSync: ObservableObject, @unchecked Sendable {
    private let container: ModelContainer
    public let deviceID: String
    private var poller: AnyCancellable?

    /// The stored states changed (another device published, or an import
    /// landed). Hand them to `LiveTimerCore.catchUp`.
    public var onStatesChanged: (([LiveState]) -> Void)?

    /// New `TimerCommand`s from any device (including this one), oldest first.
    /// Unset → commands are left unconsumed.
    public var onCommands: (([TimerCommand]) -> Void)?

    /// Fired after a debounced post-import dedup pass so the host app can
    /// refresh any caches/views that show session totals.
    public var onPostImportSettled: (() -> Void)?

    private var remoteChangeObserver: NSObjectProtocol?
    private var dedupWorkItem: DispatchWorkItem?
    private var fingerprint: (count: Int, latest: Date?) = (0, nil)

    /// Rows older than this go, but the newest few always stay.
    static let keep: TimeInterval = 48 * 3600
    static let keepAtLeast = 12

    public init(container: ModelContainer) {
        self.container = container
        self.deviceID = Self.persistedDeviceID()
        SyncLog.truncateIfLarge()
        TimerCommand.markSeenIfFirstRun()
        SyncLog.event("syncInit", ["deviceID": String(deviceID.prefix(8)), "states": allStates().count])

        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.check(force: true)
            self?.checkForCommands()
            self?.scheduleDedupAfterImport()
        }

        start()
    }

    deinit {
        if let o = remoteChangeObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    public func start() {
        guard poller == nil else { return }
        poller = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.check(force: false)
                self?.checkForCommands()
            }
    }

    public func stop() {
        poller?.cancel()
        poller = nil
    }

    /// Check now, e.g. a moment after coming to the foreground, when a
    /// push-driven import may have just landed.
    public func pokeForRemote() {
        check(force: true)
        checkForCommands()
    }

    /// Every stored state, as `LiveState`s.
    public func allStates() -> [LiveState] {
        let ctx = ModelContext(container)
        return ((try? ctx.fetch(FetchDescriptor<StoredTimerState>())) ?? []).map(Self.state)
    }

    /// Store a state for the other devices. Never edits an existing row.
    public func publish(_ s: LiveState) {
        let ctx = ModelContext(container)
        let rows = (try? ctx.fetch(FetchDescriptor<StoredTimerState>())) ?? []
        let row = StoredTimerState()
        row.id = UUID()
        Self.fill(row, from: s, version: (rows.map(\.version).max() ?? 0) + 1, sender: deviceID)
        ctx.insert(row)
        let cutoff = s.sentAt.addingTimeInterval(-Self.keep)
        let old = rows.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(Self.keepAtLeast).filter { $0.updatedAt < cutoff }
        for r in old { ctx.delete(r) }
        try? ctx.save()
        fingerprint = (rows.count + 1 - old.count, max(fingerprint.latest ?? .distantPast, row.updatedAt))
        var event = Self.describe(s)
        event["pruned"] = old.count
        SyncLog.event("statePublish", event)
    }

    /// True when a stored state matches `s` (same block, same actions).
    public func contains(_ s: LiveState) -> Bool {
        allStates().contains { !LiveState.precedes($0, s) && !LiveState.precedes(s, $0) }
    }

    private func check(force: Bool) {
        let ctx = ModelContext(container)
        var latest = FetchDescriptor<StoredTimerState>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        latest.fetchLimit = 1
        let count = (try? ctx.fetchCount(FetchDescriptor<StoredTimerState>())) ?? 0
        let newest = (try? ctx.fetch(latest))?.first?.updatedAt
        guard force || count != fingerprint.count || newest != fingerprint.latest else { return }
        fingerprint = (count, newest)
        onStatesChanged?(allStates())
    }

    private func checkForCommands() {
        guard let onCommands else { return }
        let cmds = TimerCommand.takePending(container: container, stateUpdatedAt: fingerprint.latest)
        guard !cmds.isEmpty else { return }
        for c in cmds {
            SyncLog.event("cmdApply", ["action": c.action.rawValue, "label": c.label, "createdAt": c.createdAt])
        }
        onCommands(cmds)
    }

    // MARK: - Rows

    static func state(_ r: StoredTimerState) -> LiveState {
        let phase = LiveState.Phase(rawValue: r.phaseRaw) ?? .idle
        if let stamped = r.stampedAt, abs(stamped.timeIntervalSince(r.updatedAt)) < 0.001,
           let createdAt = r.createdAt, let intentAt = r.intentAt {
            let ended = r.endedStart.map { LiveEnded(id: r.endedID, start: $0, end: r.endedAt ?? $0) }
            return LiveState(phase: phase, blockID: r.blockID, start: phase == .idle ? ended?.start : r.startTime,
                             label: r.label, breakKinds: r.breakKinds, totalSeconds: r.totalSeconds,
                             remainingSeconds: r.remainingSeconds, isRunning: r.isRunning, sentAt: r.updatedAt,
                             created: LiveStamp(at: createdAt, device: r.createdDevice ?? r.deviceID),
                             updated: LiveStamp(at: intentAt, device: r.intentDevice ?? r.deviceID),
                             ended: ended)
        }
        // Written (or last edited) by a build that didn't stamp its states.
        let stamp = LiveStamp(at: r.updatedAt, device: r.deviceID)
        let remaining = r.isRunning ? (r.endTime?.timeIntervalSince(r.updatedAt) ?? r.remainingSeconds) : r.remainingSeconds
        let ended = phase == .idle ? r.startTime.map { LiveEnded(id: nil, start: $0, end: r.endTime ?? r.updatedAt) } : nil
        return LiveState(phase: phase, blockID: nil, start: r.startTime, label: r.label, breakKinds: r.breakKinds,
                         totalSeconds: r.totalSeconds, remainingSeconds: remaining, isRunning: r.isRunning,
                         sentAt: r.updatedAt, created: stamp, updated: stamp, ended: ended, legacy: true)
    }

    /// Also fills the old fields, which builds before stamping read.
    static func fill(_ r: StoredTimerState, from s: LiveState, version: Int, sender: String) {
        r.phaseRaw = s.phase.rawValue
        r.isRunning = s.isRunning
        r.label = s.label
        r.breakKindsRaw = s.breakKinds.map(\.rawValue)
        r.totalSeconds = s.totalSeconds
        r.remainingSeconds = s.remainingSeconds
        if s.phase == .idle {
            r.startTime = s.ended?.start
            r.endTime = s.ended?.end
        } else {
            r.startTime = s.start
            r.endTime = s.endTime
        }
        r.updatedAt = s.sentAt
        r.stampedAt = s.sentAt
        r.deviceID = sender
        r.version = version
        r.blockID = s.blockID
        r.createdAt = s.created.at
        r.createdDevice = s.created.device
        r.intentAt = s.updated.at
        r.intentDevice = s.updated.device
        r.endedID = s.ended?.id
        r.endedStart = s.ended?.start
        r.endedAt = s.ended?.end
    }

    public static func describe(_ s: LiveState) -> [String: Any] {
        [
            "phase": s.phase.rawValue,
            "label": s.label,
            "running": s.isRunning,
            "block": s.blockID.map { String($0.uuidString.prefix(8)) } ?? "-",
            "start": SyncLog.opt(s.start),
            "created": "\(s.created.at.timeIntervalSince1970)@\(s.created.device.prefix(8))",
            "updated": "\(s.updated.at.timeIntervalSince1970)@\(s.updated.device.prefix(8))",
            "ended": s.ended.map { "\($0.id.map { String($0.uuidString.prefix(8)) } ?? "-") \($0.start)–\($0.end)" } ?? "-",
            "legacy": s.legacy,
        ]
    }

    /// Debounce a strict-dedup pass for ~3s after CloudKit reports new
    /// remote changes. Strict match (whole-second startTime + type + label
    /// + duration to 0.01 min) means we only ever collapse byte-identical
    /// rows — the exact failure mode where Mac and iPad both insert a row
    /// for the same broadcast-driven event with different UUIDs.
    private func scheduleDedupAfterImport() {
        dedupWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let removed = FocusMigration.dedupeWorkSessions(container: self.container)
            if removed > 0 {
                print("[TimerStateSync] post-import dedup removed \(removed) duplicate session(s)")
            }
            self.onPostImportSettled?()
        }
        dedupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    public static func persistedDeviceID() -> String {
        let key = "focusCore.timerSync.deviceID"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
}

public enum RemoteStop {
    /// Time on the clock between `start` and `end`, capped by the wall-clock
    /// span: after a relaunch the pause history before it is folded into one
    /// number, so a backdated cut once saved "start → last relaunch" (10/13:
    /// a 30-minute Math block over a 22-minute break).
    public static func duration(elapsed: TimeInterval, start: Date, end: Date) -> TimeInterval {
        min(elapsed, max(0, end.timeIntervalSince(start)))
    }
}

/// The timer's state on this device, kept across relaunches.
public enum LiveCheckpoint {
    static let key = "focusCore.liveTimer.v1"

    public static func save(_ core: LiveTimerCore) {
        guard let data = try? JSONEncoder().encode(core) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func load() -> LiveTimerCore? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LiveTimerCore.self, from: data)
    }
}
