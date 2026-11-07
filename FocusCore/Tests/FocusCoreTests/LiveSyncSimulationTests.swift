import XCTest
@testable import FocusCore

/// Seeded, so a failing run can be replayed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A Mac, an iPhone and an iPad sharing the timer. iCloud is a record store:
/// timer states are inserts, log rows are records with last-writer-wins
/// versions; each device uploads while awake and online and sees others'
/// uploads after its own delay, in any order. The local network delivers
/// states instantly between awake devices on it. Devices sleep (miss
/// everything), go offline (queue their writes), and relaunch from their
/// checkpoint. The Mac fixes overlaps on its own, as `SessionStore` does.
final class LiveSim {
    struct Version: Comparable {
        var at: Date
        var writer: String
        var seq: Int
        static func < (a: Version, b: Version) -> Bool {
            (a.at, a.writer, a.seq) < (b.at, b.writer, b.seq)
        }
    }

    struct Rec {
        var value: WorkSession?
        var version: Version
    }

    final class Device {
        let name: String
        let isMac: Bool
        var core: LiveTimerCore
        var awake = true
        var online = true
        var lan = true
        var delay: TimeInterval
        /// How far this device's clock is off.
        var skew: TimeInterval = 0
        var states: [UUID: LiveState] = [:]
        var log: [UUID: Rec] = [:]
        var outStates: [UUID: LiveState] = [:]
        var outLog: [UUID: Rec] = [:]
        var checkpoint: Data

        init(_ name: String, mac: Bool = false, delay: TimeInterval = 5) {
            self.name = name
            isMac = mac
            self.delay = delay
            core = LiveTimerCore(deviceID: name)
            checkpoint = try! JSONEncoder().encode(core)
        }

        var sessions: [WorkSession] {
            log.values.compactMap(\.value).sorted { $0.startTime < $1.startTime }
        }
    }

    var now: Date
    var devices: [Device]
    var cloudStates: [UUID: (state: LiveState, uploaded: Date)] = [:]
    var cloudLog: [UUID: (rec: Rec, uploaded: Date)] = [:]
    var rng: SplitMix
    var seq = 0
    let workSeconds: TimeInterval = 25 * 60
    var trace: [String] = []

    init(seed: UInt64 = 1, start: Date, devices: [Device]) {
        now = start
        self.devices = devices
        rng = SplitMix(state: seed)
    }

    subscript(_ name: String) -> Device { devices.first { $0.name == name }! }
    var mac: Device { devices.first(where: \.isMac)! }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    func clock(_ d: Device) -> Date { now.addingTimeInterval(d.skew) }

    // MARK: Effects

    func run(_ fx: [LiveEffect], on d: Device) {
        for e in fx {
            switch e {
            case .save(let s): save(s, on: d)
            case .publish(let st): publish(st, from: d)
            case .clear(let a, let b):
                edit(LogEdit.plan(d.sessions, start: a, end: b, label: nil, fill: false, now: now), on: d)
            case .fill(let a, let b, let label):
                edit(LogEdit.plan([], start: a, end: b, label: label, now: now), on: d)
            }
        }
        d.checkpoint = try! JSONEncoder().encode(d.core)
    }

    func write(_ id: UUID, _ value: WorkSession?, on d: Device) {
        seq += 1
        let rec = Rec(value: value, version: Version(at: now, writer: d.name, seq: seq))
        d.log[id] = rec
        d.outLog[id] = rec
    }

    func save(_ s: WorkSession, on d: Device) {
        trace.append("\(d.name) saves \(s.label ?? "Break") \(t(s.startTime))–\(t(TimeIntegrity.end(of: s)))")
        if let dupe = TimeIntegrity.sameBlock(as: s, in: d.sessions) {
            if s.durationMinutes < dupe.durationMinutes {
                write(dupe.id, with(dupe, minutes: s.durationMinutes), on: d)
            }
            return
        }
        write(s.id, s, on: d)
    }

    func edit(_ edits: [OverlapEdit], on d: Device) {
        for e in edits {
            switch e {
            case .setDuration(let id, let minutes):
                if let v = d.log[id]?.value { write(id, with(v, minutes: minutes), on: d) }
            case .delete(let id): write(id, nil, on: d)
            case .insert(let s): write(s.id, s, on: d)
            }
        }
    }

    func with(_ s: WorkSession, minutes: Double) -> WorkSession {
        WorkSession(id: s.id, startTime: s.startTime, durationMinutes: minutes, type: s.type,
                    label: s.label, breakKinds: s.breakKinds)
    }

    func publish(_ st: LiveState, from d: Device) {
        let id = UUID()
        d.states[id] = st
        d.outStates[id] = st
        guard d.lan else { return }
        for p in devices where p !== d && p.awake && p.lan { send(st, to: p, from: d) }
    }

    /// Local network: in memory, never stored. An older state gets ours back.
    func send(_ st: LiveState, to p: Device, from d: Device, reply: Bool = true) {
        if let fx = p.core.reconcile(st, now: clock(p)) {
            run(fx, on: p)
        } else if reply, let mine = p.core.currentState(at: clock(p)), LiveState.precedes(st, mine) {
            send(mine, to: d, from: p, reply: false)
        }
    }

    // MARK: Devices

    /// A user action: like the apps, catch up with what's stored first.
    func act(_ d: Device, _ what: String = "", _ body: (inout LiveTimerCore) -> [LiveEffect]) {
        precondition(d.awake, "\(d.name) is asleep")
        trace.append("\(t(now)) \(d.name): \(what)")
        run(d.core.catchUp(Array(d.states.values), now: clock(d)), on: d)
        _ = d.core.extendIfNeeded(now: clock(d))
        let fx = body(&d.core)
        run(fx, on: d)
    }

    func sleep(_ d: Device) { d.awake = false }

    func wake(_ d: Device) {
        guard !d.awake else { return }
        d.awake = true
        _ = d.core.extendIfNeeded(now: clock(d))
        run(d.core.catchUp(Array(d.states.values), now: clock(d)), on: d)
        exchange(d)
    }

    /// Killed and reopened: the checkpoint is all it keeps of the timer.
    func relaunch(_ d: Device) {
        d.core = try! JSONDecoder().decode(LiveTimerCore.self, from: d.checkpoint)
        d.awake = true
        run(d.core.catchUp(Array(d.states.values), now: clock(d)), on: d)
        if let mine = d.core.currentState(at: clock(d)),
           !d.states.values.contains(where: { !LiveState.precedes($0, mine) && !LiveState.precedes(mine, $0) }) {
            publish(mine, from: d)
        }
        exchange(d)
    }

    /// Peers that just found each other on the network swap states.
    func exchange(_ d: Device) {
        guard d.lan, d.awake else { return }
        for p in devices where p !== d && p.awake && p.lan {
            if let mine = d.core.currentState(at: clock(d)) { send(mine, to: p, from: d) }
            if let theirs = p.core.currentState(at: clock(p)) { send(theirs, to: d, from: p) }
        }
    }

    // MARK: iCloud

    func sync() {
        for d in devices where d.awake && d.online {
            for (id, st) in d.outStates { cloudStates[id] = (st, now) }
            d.outStates = [:]
            for (id, rec) in d.outLog {
                if let c = cloudLog[id], rec.version < c.rec.version { continue }
                cloudLog[id] = (rec, now)
            }
            d.outLog = [:]
        }
        for d in devices where d.awake && d.online {
            var incoming = cloudStates.filter { d.states[$0.key] == nil && $0.value.uploaded.addingTimeInterval(d.delay) <= now }
                .map { ($0.key, $0.value.state) }
            incoming.shuffle(using: &rng)
            for (id, st) in incoming { d.states[id] = st }
            for (id, v) in cloudLog where v.uploaded.addingTimeInterval(d.delay) <= now {
                if let mine = d.log[id], !(mine.version < v.rec.version) { continue }
                d.log[id] = v.rec
            }
            if !incoming.isEmpty { run(d.core.catchUp(Array(d.states.values), now: clock(d)), on: d) }
            if d.isMac { resolve(on: d) }
        }
    }

    func resolve(on d: Device) {
        for _ in 0..<300 {
            guard let o = TimeIntegrity.overlaps(in: d.sessions, from: now.addingTimeInterval(-30 * 86400),
                                                 to: now.addingTimeInterval(1)).first else { return }
            let fix = TimeIntegrity.autoFix(o)
            let edits = fix.removing.map(TimeIntegrity.remove)
                ?? fix.keep.map { TimeIntegrity.resolve(o, keep: $0, now: now) }
                ?? TimeIntegrity.merge(o, now: now)
            edit(edits, on: d)
        }
    }

    /// Everyone awake and online until nothing more moves.
    func settle() {
        for d in devices {
            d.online = true
            d.lan = true
            wake(d)
        }
        let wait = (devices.map(\.delay).max() ?? 0) + 1
        for _ in 0..<8 {
            sync()
            advance(wait)
        }
        sync()
    }

    // MARK: Checks

    static func key(_ s: LiveState?) -> String {
        guard let s else { return "none" }
        return [s.phase.rawValue, s.blockID?.uuidString ?? "-", s.label, "\(s.isRunning)",
                s.start.map { "\($0.timeIntervalSince1970)" } ?? "-",
                "\(s.created.at.timeIntervalSince1970)@\(s.created.device)",
                "\(s.updated.at.timeIntervalSince1970)@\(s.updated.device)"].joined(separator: "|")
    }

    func t(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    var dump: String {
        let rows = mac.sessions.map { "  \($0.label ?? "Break") \(t($0.startTime))–\(t(TimeIntegrity.end(of: $0)))" }
        let states = devices.map { "  \($0.name): \(Self.key($0.core.currentState(at: now)))" }
        return (["trace:"] + trace.suffix(80) + ["mac log:"] + rows + ["states:"] + states).joined(separator: "\n")
    }

    func assertConverged(file: StaticString = #filePath, line: UInt = #line) {
        let keys = devices.map { Self.key($0.core.currentState(at: now)) }
        XCTAssertEqual(Set(keys).count, 1, "devices disagree\n\(dump)", file: file, line: line)
        let best = cloudStates.values.map(\.state).max { LiveState.precedes($0, $1) }
        XCTAssertEqual(keys.first, Self.key(best), "not the newest action\n\(dump)", file: file, line: line)
    }

    func assertLogsClean(file: StaticString = #filePath, line: UInt = #line) {
        let reference = Self.rows(mac.sessions)
        for d in devices where d !== mac {
            XCTAssertEqual(Self.rows(d.sessions), reference, "\(d.name)'s log differs from the Mac's\n\(dump)",
                           file: file, line: line)
        }
        let overlaps = TimeIntegrity.overlaps(in: mac.sessions, from: .distantPast, to: .distantFuture)
        XCTAssertTrue(overlaps.isEmpty, "\(overlaps.count) overlaps\n\(dump)", file: file, line: line)
        for s in mac.sessions {
            XCTAssertLessThanOrEqual(TimeIntegrity.end(of: s), now.addingTimeInterval(11), "row in the future\n\(dump)",
                                     file: file, line: line)
        }
    }

    static func rows(_ s: [WorkSession]) -> [String] {
        s.map { "\($0.label ?? "Break")|\(Int($0.startTime.timeIntervalSince1970))|\(Int(($0.durationMinutes * 60).rounded()))" }
            .sorted { a, b in
                let x = a.split(separator: "|"), y = b.split(separator: "|")
                return (Int(x[1])!, a) < (Int(y[1])!, b)
            }
    }

    /// What's logged at each minute's midpoint ("-" untracked).
    static func coverage(_ sessions: [WorkSession], from: Date, to: Date) -> [String] {
        var out: [String] = []
        var m = from.addingTimeInterval(30)
        while m < to {
            let hits = sessions.filter { $0.startTime <= m && TimeIntegrity.end(of: $0) > m }
            out.append(hits.isEmpty ? "-" : hits.count > 1 ? "!" : (hits[0].label ?? "Break"))
            m = m.addingTimeInterval(60)
        }
        return out
    }
}

/// One device, everything in order: what the synced devices must add up to.
final class SoloTimer {
    var core = LiveTimerCore(deviceID: "solo")
    var log: [UUID: WorkSession] = [:]

    func run(_ fx: [LiveEffect], now: Date) {
        for e in fx {
            switch e {
            case .save(let s): log[s.id] = s
            case .publish: break
            case .clear(let a, let b):
                for edit in LogEdit.plan(Array(log.values), start: a, end: b, label: nil, fill: false, now: now) {
                    switch edit {
                    case .setDuration(let id, let m):
                        let v = log[id]!
                        log[id] = WorkSession(id: id, startTime: v.startTime, durationMinutes: m, type: v.type,
                                              label: v.label, breakKinds: v.breakKinds)
                    case .delete(let id): log[id] = nil
                    case .insert(let s): log[s.id] = s
                    }
                }
            case .fill: break
            }
        }
    }
}

final class LiveSyncSimulationTests: XCTestCase {
    let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
    let labels = ["Math", "SWE", "Leisure", "Reading", "Meals", "AI"]

    enum Step {
        case switchTo(String, back: TimeInterval)
        case stop(back: TimeInterval)
        case breakOpen
        case pause, resume
        case moveStart(TimeInterval)
        case relabel(String)
    }

    func randomStep(_ core: LiveTimerCore, now: Date, rng: inout SplitMix, updates: Bool) -> Step {
        let label = labels.randomElement(using: &rng)!
        let roll = Int.random(in: 0..<100, using: &rng)
        let back = Bool.random(using: &rng) ? 0 : TimeInterval(Int.random(in: 1...20, using: &rng) * 60)
        guard let b = core.block else { return roll < 85 ? .switchTo(label, back: back) : .breakOpen }
        switch roll {
        case ..<45: return .switchTo(label, back: back)
        case ..<55: return .stop(back: back)
        case ..<63: return .breakOpen
        default: break
        }
        guard updates else { return .switchTo(label, back: 0) }
        switch roll {
        case ..<72: return b.isRunning ? .pause : .resume
        case ..<86:
            let elapsed = now.timeIntervalSince(b.start)
            let later = elapsed > 240 ? Double(Int.random(in: 60...Int(elapsed / 2), using: &rng)) : 0
            let earlier = -Double(Int.random(in: 1...25, using: &rng) * 60)
            return .moveStart(Bool.random(using: &rng) && later > 0 ? later : earlier)
        default: return .relabel(label)
        }
    }

    func apply(_ step: Step, to core: inout LiveTimerCore, now: Date, workSeconds: TimeInterval) -> [LiveEffect] {
        switch step {
        case .switchTo(let l, let back): return core.switchTo(l, at: now.addingTimeInterval(-back), workSeconds: workSeconds, now: now)
        case .stop(let back): return core.stop(at: now.addingTimeInterval(-back), now: now)
        case .breakOpen: return core.startBreak(minutes: 0, label: core.block?.label ?? "", at: now, now: now)
        case .pause: return core.pause(now: now)
        case .resume: return core.resume(now: now)
        case .moveStart(let d): return core.moveStart(to: core.block!.start.addingTimeInterval(d), now: now)
        case .relabel(let l): return core.relabel(l, workSeconds: workSeconds, now: now)
        }
    }

    func devices() -> [LiveSim.Device] {
        [LiveSim.Device("mac", mac: true, delay: 8), LiveSim.Device("iphone", delay: 20), LiveSim.Device("ipad", delay: 45)]
    }

    /// Synced devices taking turns behave exactly like one device.
    func testTakingTurnsMatchesOneDevice() {
        for seed in 1...300 as ClosedRange<UInt64> {
            var rng = SplitMix(state: seed)
            let sim = LiveSim(seed: seed, start: start, devices: devices())
            sim.devices.forEach { $0.lan = Bool.random(using: &rng) }
            let solo = SoloTimer()
            for _ in 0..<40 {
                sim.advance(TimeInterval(Int.random(in: 2...40, using: &rng) * 60 + Int.random(in: 0...59, using: &rng)))
                let d = sim.devices.randomElement(using: &rng)!
                let step = randomStep(solo.core, now: sim.now, rng: &rng, updates: true)
                sim.act(d, "\(step)") { apply(step, to: &$0, now: sim.now, workSeconds: sim.workSeconds) }
                solo.run(apply(step, to: &solo.core, now: sim.now, workSeconds: sim.workSeconds), now: sim.now)
                sim.settle()
            }
            sim.assertConverged()
            sim.assertLogsClean()
            let want = LiveSim.coverage(Array(solo.log.values), from: start, to: sim.now)
            let got = LiveSim.coverage(sim.mac.sessions, from: start, to: sim.now)
            if want != got {
                let i = want.indices.first { $0 >= got.count || want[$0] != got[$0] } ?? 0
                XCTFail("seed \(seed): minute \(i) solo \(want[i]) synced \(got[i])\n\(sim.dump)")
                return
            }
        }
    }

    /// Anything goes: stale devices acting, sleeping, offline, relaunching,
    /// acting at the same moment. Once everyone is back they agree on what's
    /// running (the newest action) and on one log with no double counting.
    func testChaosConverges() {
        let only = ProcessInfo.processInfo.environment["CHAOS_SEED"].flatMap(UInt64.init)
        let count = ProcessInfo.processInfo.environment["CHAOS_COUNT"].flatMap(UInt64.init) ?? 400
        for seed in only.map({ $0...$0 }) ?? (1...count) {
            var rng = SplitMix(state: seed &* 7919)
            let sim = LiveSim(seed: seed, start: start, devices: devices())
            for d in sim.devices {
                d.delay = TimeInterval(Int.random(in: 2...120, using: &rng))
                if !d.isMac && seed % 2 == 0 { d.skew = TimeInterval(Int.random(in: -5...5, using: &rng)) }
            }
            for _ in 0..<60 {
                sim.advance(TimeInterval(Int.random(in: 20...1500, using: &rng)))
                let d = sim.devices.randomElement(using: &rng)!
                switch Int.random(in: 0..<100, using: &rng) {
                case ..<55:
                    guard d.awake else { sim.wake(d); continue }
                    let step = randomStep(d.core, now: sim.clock(d), rng: &rng, updates: true)
                    sim.act(d, "\(step)") { apply(step, to: &$0, now: sim.clock(d), workSeconds: sim.workSeconds) }
                case ..<65: sim.sleep(d)
                case ..<75: sim.wake(d)
                case ..<80: d.online.toggle()
                case ..<85: d.lan.toggle()
                case ..<90: sim.relaunch(d)
                default: sim.sync()
                }
                if Bool.random(using: &rng) { sim.sync() }
            }
            sim.settle()
            sim.assertConverged()
            sim.assertLogsClean()
            if only != nil { print(sim.dump) }
            if testRun?.failureCount ?? 0 > 0 { XCTFail("seed \(seed)"); return }
        }
    }

    // MARK: - From real logs

    /// 10/28–29: Class started on the Mac at 9:25, the Mac was shut for a
    /// day, the phone stopped Class at 11:00. Reopened, the Mac logged Class
    /// for 23 hours.
    func testMacReopenedAfterPhoneStoppedKeepsPhonesEnd() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Class") { $0.switchTo("Class", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.sleep(sim.mac)
        sim.advance(95 * 60)
        let stopped = sim.now
        sim.act(sim["iphone"], "stop") { $0.stop(at: sim.now, now: sim.now) }
        sim.sync()
        sim.advance(22 * 3600)
        sim.relaunch(sim.mac)
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions), ["Class|\(Int(start.timeIntervalSince1970))|\(Int(stopped.timeIntervalSince(start)))"], sim.dump)
        XCTAssertNil(sim.mac.core.block)
    }

    /// 10/24: an iPad left on LeetCode for five days came back and logged
    /// 22.6 hours of it.
    func testIPadAsleepForDaysCannotBringBackItsBlock() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim["ipad"], "LeetCode") { $0.switchTo("LeetCode", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.sleep(sim["ipad"])
        sim.advance(40 * 60)
        let leetMinutes = sim.now.timeIntervalSince(start) / 60
        sim.act(sim.mac, "Leisure") { $0.switchTo("Leisure", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.advance(3 * 3600)
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(5 * 86400)
        sim.relaunch(sim["ipad"])
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        let leet = sim.mac.sessions.filter { $0.label == "LeetCode" }
        XCTAssertEqual(leet.map(\.durationMinutes).reduce(0, +), leetMinutes, accuracy: 0.1, sim.dump)
        XCTAssertEqual(sim["ipad"].core.block?.label, "Math")
    }

    /// The phone opened before iCloud caught up, still showing Math from
    /// 9:00, while the Mac had switched to Reading at 9:30.
    func testStalePhoneSwitchKeepsTheMacsHandover() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.sleep(sim["iphone"])
        sim["iphone"].lan = false
        sim.advance(30 * 60)
        let reading = sim.now
        sim.act(sim.mac, "Reading") { $0.switchTo("Reading", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(30 * 60)
        let leisure = sim.now
        sim["iphone"].awake = true
        sim.act(sim["iphone"], "Leisure") { $0.switchTo("Leisure", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        let s = Int(start.timeIntervalSince1970), r = Int(reading.timeIntervalSince1970)
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions),
                       ["Math|\(s)|\(r - s)", "Reading|\(r)|\(Int(leisure.timeIntervalSince(reading)))"], sim.dump)
        XCTAssertEqual(sim.mac.core.block?.label, "Leisure")
    }

    /// The Mac stopped Math at 9:30; the phone, still showing Math, switched
    /// at 10:00 and logged its stale Math to 10:00. The earlier end wins and
    /// 9:30–10:00 stays untracked.
    func testStalePhoneDoesNotStretchAStoppedBlock() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.sleep(sim["iphone"])
        sim["iphone"].lan = false
        sim.advance(30 * 60)
        let stopped = sim.now
        sim.act(sim.mac, "stop") { $0.stop(at: sim.now, now: sim.now) }
        sim.sync()
        sim.advance(30 * 60)
        sim["iphone"].awake = true
        sim.act(sim["iphone"], "Leisure") { $0.switchTo("Leisure", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions),
                       ["Math|\(Int(start.timeIntervalSince1970))|\(Int(stopped.timeIntervalSince(start)))"], sim.dump)
    }

    /// Pausing a block another device already replaced doesn't bring it back.
    func testStalePauseDoesNotReviveReplacedBlock() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.sleep(sim["iphone"])
        sim["iphone"].lan = false
        sim.advance(30 * 60)
        sim.act(sim.mac, "Reading") { $0.switchTo("Reading", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(30 * 60)
        sim["iphone"].awake = true
        sim.act(sim["iphone"], "pause") { $0.pause(now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(sim["iphone"].core.block?.label, "Reading")
        XCTAssertEqual(sim["iphone"].core.block?.isRunning, true)
    }

    /// The phone was idle (stopped last night) and switched while the Mac
    /// ran Math: the Mac logs its Math up to the switch.
    func testIdlePhoneSwitchLogsTheMacsBlock() {
        let sim = LiveSim(start: start, devices: devices())
        sim["iphone"].awake = false
        sim["iphone"].lan = false
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(3600)
        sim["iphone"].awake = true
        sim.act(sim["iphone"], "Leisure") { $0.switchTo("Leisure", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions), ["Math|\(Int(start.timeIntervalSince1970))|3600"], sim.dump)
    }

    /// Stop on a phone that has nothing running stops the Mac.
    func testStopFromIdlePhoneStopsMac() {
        let sim = LiveSim(start: start, devices: devices())
        sim["iphone"].awake = false
        sim["iphone"].lan = false
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(1200)
        sim["iphone"].awake = true
        sim.act(sim["iphone"], "stop") { $0.stop(at: sim.now, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertNil(sim.mac.core.block)
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions), ["Math|\(Int(start.timeIntervalSince1970))|1200"], sim.dump)
    }

    /// Two devices switching within a second of each other.
    func testSimultaneousSwitchesAgree() {
        let sim = LiveSim(start: start, devices: devices())
        sim.devices.forEach { $0.lan = false }
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.devices.forEach { $0.lan = false }
        sim.advance(1800)
        sim.act(sim.mac, "SWE") { $0.switchTo("SWE", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.advance(1)
        sim.act(sim["iphone"], "Meals") { $0.switchTo("Meals", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(sim.mac.core.block?.label, "Meals")
    }

    /// "Started later than that": the time before is left untracked
    /// everywhere, not logged as the old start by another device.
    func testMovingStartLaterLeavesAGapEverywhere() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Chores") { $0.switchTo("Chores", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.advance(600)
        let later = sim.now.addingTimeInterval(-120)
        sim.act(sim["iphone"], "move") { $0.moveStart(to: later, now: sim.now) }
        sim.settle()
        let stopped = sim.now
        sim.act(sim.mac, "stop") { $0.stop(at: sim.now, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        let end = stopped.timeIntervalSince(later)
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions).count, 1, sim.dump)
        XCTAssertEqual(sim.mac.sessions.first?.startTime, later)
        XCTAssertEqual(end, sim.mac.sessions.first!.durationMinutes * 60, accuracy: 1)
    }

    /// "Started earlier": what was logged in between becomes the running block.
    func testMovingStartEarlierTakesOverLoggedTime() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Reading") { $0.switchTo("Reading", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.advance(7200)
        let chores = sim.now
        sim.act(sim.mac, "Chores") { $0.switchTo("Chores", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.advance(600)
        let earlier = chores.addingTimeInterval(-3600)
        sim.act(sim["iphone"], "move") { $0.moveStart(to: earlier, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions), ["Reading|\(Int(start.timeIntervalSince1970))|\(Int(earlier.timeIntervalSince(start)))"], sim.dump)
        XCTAssertEqual(sim.mac.core.block?.start, earlier)
        XCTAssertEqual(sim.mac.core.block?.label, "Chores")
    }

    /// A finished countdown rolls into overtime on its own on every device;
    /// a state received after its countdown ended still runs.
    func testOvertimeKeepsRunningOnPeers() {
        let sim = LiveSim(start: start, devices: devices())
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.sync()
        sim.advance(3600)
        sim.settle()
        sim.assertConverged()
        for d in sim.devices {
            XCTAssertEqual(d.core.block?.isRunning, true, d.name)
            XCTAssertEqual(d.core.block!.elapsed(at: sim.now), sim.now.timeIntervalSince(start), accuracy: 1)
        }
    }

    /// An old build sending its stale block with a fresh timestamp.
    func testLegacyStaleAnnouncementIgnored() {
        var core = LiveTimerCore(deviceID: "mac")
        let now = start.addingTimeInterval(7200)
        _ = core.switchTo("Math", at: start.addingTimeInterval(3600), workSeconds: 1500, now: start.addingTimeInterval(3600))
        let stale = LiveState(phase: .work, blockID: nil, start: start, label: "LeetCode", breakKinds: [],
                              totalSeconds: 90000, remainingSeconds: 80000, isRunning: true, sentAt: now,
                              created: LiveStamp(at: now, device: "ipad"), updated: LiveStamp(at: now, device: "ipad"),
                              ended: nil, legacy: true)
        XCTAssertNil(core.reconcile(stale, now: now))
        XCTAssertEqual(core.block?.label, "Math")
    }

    /// 10/16: the Mac stopped Exercise at 11:13 PM; at 8:29 AM an old-build
    /// iPad announced Math running from Exercise's start, and the idle Mac
    /// took it (the start wasn't older than the block it had ended).
    func testLegacyResurrectionOfStoppedBlockIgnored() {
        var core = LiveTimerCore(deviceID: "mac")
        let exercise = start
        _ = core.switchTo("Exercise", at: exercise, workSeconds: 0, now: exercise)
        _ = core.stop(at: exercise.addingTimeInterval(4 * 3600), now: exercise.addingTimeInterval(4 * 3600))
        XCTAssertNil(core.block)
        let now = exercise.addingTimeInterval(13 * 3600)
        for offset in [0.0, 2.0, -2.0] {
            let resurrected = LiveState(phase: .work, blockID: nil, start: exercise.addingTimeInterval(offset),
                                        label: "Math", breakKinds: [], totalSeconds: 90000, remainingSeconds: 90000 - 13 * 3600,
                                        isRunning: true, sentAt: now,
                                        created: LiveStamp(at: now, device: "ipad"), updated: LiveStamp(at: now, device: "ipad"),
                                        ended: nil, legacy: true)
            XCTAssertNil(core.reconcile(resurrected, now: now), "offset \(offset)")
            XCTAssertNil(core.block)
        }
        let fresh = LiveState(phase: .work, blockID: nil, start: now, label: "Reading", breakKinds: [],
                              totalSeconds: 86400, remainingSeconds: 86400, isRunning: true, sentAt: now,
                              created: LiveStamp(at: now, device: "ipad"), updated: LiveStamp(at: now, device: "ipad"),
                              ended: nil, legacy: true)
        XCTAssertNotNil(core.reconcile(fresh, now: now))
        XCTAssertEqual(core.block?.label, "Reading")
    }

    /// First launch of this build: each device restores its old checkpoint.
    /// The iPad's is LeetCode from five days ago; the Mac's is today's Chores,
    /// which the phone also had. Nobody logs the stale LeetCode, and the two
    /// restored copies of Chores are one block.
    func testUpgradeFromOldCheckpointsLogsNoStaleBlock() {
        let sim = LiveSim(start: start, devices: devices())
        let now = start.addingTimeInterval(5 * 86400)
        sim.now = now
        let chores = now.addingTimeInterval(-600)
        sim.mac.core.restoreLegacy(start: chores, elapsedBeforePause: 600, totalTime: 86400, label: "Chores",
                                   isBreak: false, kinds: [], wasRunning: true, now: now)
        sim["iphone"].core.restoreLegacy(start: chores, elapsedBeforePause: 600, totalTime: 86400, label: "Chores",
                                         isBreak: false, kinds: [], wasRunning: true, now: now)
        sim["ipad"].core.restoreLegacy(start: start, elapsedBeforePause: 5 * 86400, totalTime: 90000, label: "LeetCode",
                                       isBreak: false, kinds: [], wasRunning: true, now: now)
        for d in sim.devices { d.checkpoint = try! JSONEncoder().encode(d.core) }
        sim.mac.lan = false
        sim.relaunch(sim.mac)
        sim.relaunch(sim["iphone"])
        sim.settle()
        sim.assertConverged()
        XCTAssertEqual(sim.mac.sessions.count, 0, sim.dump)
        XCTAssertEqual(sim["ipad"].core.block?.label, "Chores")
        XCTAssertEqual(sim["ipad"].core.block?.start, chores)
        sim.advance(600)
        sim.act(sim["iphone"], "Meals") { $0.switchTo("Meals", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions).map { $0.split(separator: "|")[0] }, ["Chores"], sim.dump)
    }

    /// A Shortcut command applied by two devices makes one block.
    func testCommandAppliedTwiceIsOneBlock() {
        let sim = LiveSim(start: start, devices: devices())
        sim.devices.forEach { $0.lan = false }
        sim.act(sim.mac, "Math") { $0.switchTo("Math", at: sim.now, workSeconds: 1500, now: sim.now) }
        sim.settle()
        sim.devices.forEach { $0.lan = false }
        sim.advance(1800)
        let cmd = UUID()
        let at = sim.now
        let math = Int(at.timeIntervalSince(start))
        sim.act(sim.mac, "cmd") { $0.switchTo("Meals", at: at, workSeconds: 1500, now: sim.now, id: cmd) }
        sim.advance(20)
        sim.act(sim["iphone"], "cmd") { $0.switchTo("Meals", at: at, workSeconds: 1500, now: sim.now, id: cmd) }
        sim.settle()
        sim.assertConverged()
        sim.assertLogsClean()
        XCTAssertEqual(LiveSim.rows(sim.mac.sessions), ["Math|\(Int(start.timeIntervalSince1970))|\(math)"], sim.dump)
    }
}
