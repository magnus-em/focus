import AppKit
import FocusCore

/// Writes `WindowTimeline` rows: the front app/window/tab every time it
/// changes (checked each second), keyboard/mouse counts every 5 s, a heartbeat
/// every 20 s and away marks. Reads window titles the same way the screen
/// watcher does (no capture), and only while screen watching is on. Private
/// apps get no title; browser windows get a title and address only when the
/// Chrome extension reports the same regular (not incognito) tab.
@MainActor
final class WindowTimelineRecorder {
    static let shared = WindowTimelineRecorder()
    nonisolated static let keepDays = 365

    struct Front: Equatable {
        var app: String
        var bundle: String
        var title: String?
        var url: String?
    }

    private(set) var front: Front?
    /// When the current front app came to the front.
    private(set) var frontSince = Date()
    private var pending: (front: Front, seen: Int)?
    private var recent: [WindowTimeline.Event] = []
    private var timer: Timer?
    private var lastPoll = Date()
    private var polls = 0
    private var away = false
    private var counters: [Int] = []
    private var buffer: [WindowTimeline.Event] = []
    private var settings: AppSettings?
    private let io = DispatchQueue(label: "focus.timeline.io", qos: .utility)

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/timeline", isDirectory: true)
    }

    func start(settings: AppSettings) {
        self.settings = settings
        guard timer == nil else { return }
        counters = Self.readCounters()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.2
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(.away(Date(), reason: "quit"))
                self?.flush(sync: true)
            }
        }
        io.async { Self.prune() }
    }

    private func poll() {
        let now = Date()
        defer { lastPoll = now }
        guard settings?.screenWatch == true else {
            if front != nil { emit(.away(now, reason: "off")); front = nil; flush() }
            return
        }
        if now.timeIntervalSince(lastPoll) > 10, front != nil {
            emit(.away(lastPoll, reason: "gap"))
            front = nil
        }
        if PresenceMonitor.shared.isAway {
            if !away {
                away = true
                if front != nil { emit(.away(now.addingTimeInterval(-min(PresenceMonitor.idleSeconds, 3600)), reason: "away")) }
                front = nil
                flush()
            }
            return
        }
        away = false
        polls += 1
        if let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier {
            let seen = read(app, bundle: bundle)
            if seen != front {
                if front == nil || seen.bundle != front?.bundle {
                    switchTo(seen, at: now)
                } else if let p = pending, p.front == seen {
                    if p.seen + 1 >= 2 { switchTo(seen, at: now.addingTimeInterval(-1)) } else { pending = (seen, p.seen + 1) }
                } else {
                    pending = (seen, 1)
                }
            } else {
                pending = nil
            }
        }
        if Calendar.current.component(.day, from: now) != Calendar.current.component(.day, from: lastPoll), let f = front {
            emit(.window(now, app: f.app, bundle: f.bundle, title: f.title, url: f.url))
        }
        if polls % 5 == 0 {
            let c = Self.readCounters()
            let d = zip(c, counters).map { max(0, $0 - $1) }
            counters = c
            if d.contains(where: { $0 > 0 }) {
                emit(.input(now, keys: d[0], clicks: d[1], scrolls: d[2], moves: d[3]))
            }
            flush()
        }
        if polls % 20 == 0 { emit(.alive(now)) }
    }

    private func switchTo(_ f: Front, at: Date) {
        if f.bundle != front?.bundle { frontSince = at }
        front = f
        pending = nil
        emit(.window(at, app: f.app, bundle: f.bundle, title: f.title, url: f.url))
    }

    private func read(_ app: NSRunningApplication, bundle: String) -> Front {
        let name = app.localizedName ?? bundle
        if ScreenWatcher.privateApps.contains(bundle) || ScreenWatcher.userIgnored[bundle] != nil {
            return Front(app: name, bundle: bundle)
        }
        let raw = Self.title(pid: app.processIdentifier).map(WindowTimeline.normalizedTitle) ?? ""
        if ScreenWatcher.browsers.contains(bundle) {
            guard let tab = BrowserBridge.shared.activeTab, Date().timeIntervalSince(tab.at) < 300, !tab.title.isEmpty,
                  !raw.isEmpty, raw.hasPrefix(tab.title) || tab.title.hasPrefix(raw) else {
                return Front(app: name, bundle: bundle)
            }
            return Front(app: name, bundle: bundle, title: raw, url: tab.url)
        }
        return Front(app: name, bundle: bundle, title: raw.isEmpty ? nil : raw)
    }

    private static func title(pid: pid_t) -> String? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.first {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == pid
        }.map { $0[kCGWindowName as String] as? String ?? "" }
    }

    private static func readCounters() -> [Int] {
        let s = CGEventSourceStateID.combinedSessionState
        let n = { (t: CGEventType) in Int(CGEventSource.counterForEventType(s, eventType: t)) }
        return [n(.keyDown), n(.leftMouseDown) + n(.rightMouseDown), n(.scrollWheel),
                n(.mouseMoved) + n(.leftMouseDragged)]
    }

    // MARK: - Recent memory (for stitching screen readings together)

    /// Whether `bundle` stayed in front, with no away mark, over the range,
    /// judged from the last two hours of rows.
    func wasFront(bundle: String, from: Date, to: Date) -> Bool {
        guard to > from, let first = recent.first, first.at <= from else { return false }
        var current: String?
        for e in recent {
            if e.at > to { break }
            switch e.kind {
            case .window: if e.at <= from { current = e.bundle } else if e.bundle != bundle { return false }
            case .away: if e.at > from { return false } else { current = nil }
            default: break
            }
        }
        return current == bundle
    }

    // MARK: - Writing

    private func emit(_ e: WindowTimeline.Event) {
        buffer.append(e)
        recent.append(e)
        let cutoff = Date().addingTimeInterval(-7200)
        if let i = recent.firstIndex(where: { $0.at >= cutoff }), i > 0 {
            if let lastWindow = recent[..<i].last(where: { $0.kind == .window || $0.kind == .away }) {
                recent = [lastWindow] + recent[i...]
            } else {
                recent.removeFirst(i)
            }
        }
    }

    private func flush(sync: Bool = false) {
        guard !buffer.isEmpty else { return }
        let rows = buffer
        buffer = []
        let work = {
            let enc = JSONEncoder()
            var byDay: [String: Data] = [:]
            for r in rows {
                guard let d = try? enc.encode(r) else { continue }
                byDay[Self.dayKey(r.at), default: Data()].append(d + Data("\n".utf8))
            }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for (day, data) in byDay {
                let url = Self.directory.appendingPathComponent("\(day).jsonl")
                if let h = try? FileHandle(forWritingTo: url) {
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                    try? h.close()
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        if sync { io.sync(execute: work) } else { io.async(execute: work) }
    }

    nonisolated static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    nonisolated private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let cutoff = dayKey(Date().addingTimeInterval(-Double(keepDays) * 86400))
        for f in files where f.pathExtension == "jsonl" && f.lastPathComponent.prefix(10) < cutoff {
            try? fm.removeItem(at: f)
        }
    }

    // MARK: - Reading

    /// Rows for [from, to), plus the last window row before `from` so the
    /// first stretch knows what was in front.
    nonisolated static func events(from: Date, to: Date) -> [WindowTimeline.Event] {
        let dec = JSONDecoder()
        var out: [WindowTimeline.Event] = []
        var day = Calendar.current.startOfDay(for: from).addingTimeInterval(-86400)
        while day < to {
            let url = directory.appendingPathComponent("\(dayKey(day)).jsonl")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    if let e = try? dec.decode(WindowTimeline.Event.self, from: Data(line.utf8)) { out.append(e) }
                }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? to
        }
        out.sort { $0.at < $1.at }
        let lead = out.last { $0.at < from && ($0.kind == .window || $0.kind == .away) }
        let inRange = out.filter { $0.at >= from && $0.at < to }
        if let lead, lead.kind == .window, from.timeIntervalSince(lead.at) < 12 * 3600 {
            var l = lead
            let lastBefore = out.last { $0.at < from }?.at ?? lead.at
            if from.timeIntervalSince(lastBefore) <= WindowTimeline.recorderGap { l.at = from }
            return [l] + inRange
        }
        return inRange
    }
}
