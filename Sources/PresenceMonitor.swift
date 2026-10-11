import AppKit
import CoreGraphics

/// A stretch when nobody was at this Mac.
struct AwaySpan: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date
    /// lock, display, sleep, idle, or pmset (backfilled from the power log).
    var reason: String
    var id: Date { start }
    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

/// Watches whether anyone is at this Mac: screen lock, display sleep, system
/// sleep and keyboard/mouse idle. Away spans are device-local evidence for
/// prompts, the morning review and the week view; nothing becomes a session
/// unless the user picks a category for it.
final class PresenceMonitor: ObservableObject {
    static let shared = PresenceMonitor()

    @Published private(set) var spans: [AwaySpan] = []
    /// Start of the current unbroken stretch at the Mac.
    @Published private(set) var presentSince = Date()
    @Published private(set) var isAway = false

    /// Fired on return from an away stretch long enough to keep.
    var onReturn: ((AwaySpan) -> Void)?

    /// Input idle this long counts as away (backdated to the last input).
    static let idleAwaySeconds: TimeInterval = 10 * 60
    private static let minSpanSeconds: TimeInterval = 10 * 60
    private static let keepDays = 60

    private var awayStart: Date?
    private var awayReason = ""
    private var screenLocked = false
    private var displayAsleep = false
    private var poll: Timer?
    private var observers: [NSObjectProtocol] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presence.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([AwaySpan].self, from: data) {
            spans = saved
        }
    }

    func start() {
        guard poll == nil else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        observers = [
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.displayAsleep = true; self?.markAway("display")
            },
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.displayAsleep = false
            },
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.markAway("sleep")
            },
            dist.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = true; self?.markAway("lock")
            },
            dist.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.screenLocked = false; self?.check()
            },
        ]
        poll = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let backfill = Self.displayOffSpansFromPowerLog()
            DispatchQueue.main.async { self?.merge(backfill) }
        }
    }

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Away spans overlapping [from, to), clipped to it.
    func spans(from: Date, to: Date, minMinutes: Double = 0) -> [AwaySpan] {
        spans.compactMap { s in
            let a = max(s.start, from), b = min(s.end, to)
            guard b.timeIntervalSince(a) >= max(1, minMinutes * 60) else { return nil }
            return AwaySpan(start: a, end: b, reason: s.reason)
        }
    }

    // MARK: - State

    private func markAway(_ reason: String) {
        guard awayStart == nil else { return }
        // Away began at the last input, not when the screen locked or slept.
        awayStart = Date().addingTimeInterval(-min(Self.idleSeconds, 6 * 3600))
        awayReason = reason
        isAway = true
    }

    private func check() {
        let idle = Self.idleSeconds
        if awayStart == nil {
            if idle >= Self.idleAwaySeconds { markAway("idle") }
            return
        }
        // Back = fresh input on an unlocked, lit screen.
        guard !screenLocked, !displayAsleep, idle < 15 else { return }
        markBack(at: Date().addingTimeInterval(-idle))
    }

    private func markBack(at date: Date) {
        guard let start = awayStart else { return }
        awayStart = nil
        isAway = false
        presentSince = date
        guard date.timeIntervalSince(start) >= Self.minSpanSeconds else { return }
        let span = AwaySpan(start: start, end: date, reason: awayReason)
        merge([span])
        onReturn?(span)
    }

    private func merge(_ new: [AwaySpan]) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: Date())!
        var out: [AwaySpan] = []
        for s in (spans + new).filter({ $0.end > cutoff }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start.timeIntervalSince(last.end) < 60 {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        guard out != spans else { return }
        spans = out
        if let data = try? JSONEncoder().encode(out) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Display-off stretches from `pmset -g log` (about a week of history),
    /// so time the app wasn't running for still has evidence.
    private static func displayOffSpansFromPowerLog() -> [AwaySpan] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "log"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var out: [AwaySpan] = []
        var offAt: Date?
        text.enumerateLines { line, _ in
            guard line.contains("Display is turned"), line.count > 25,
                  let t = f.date(from: String(line.prefix(25))) else { return }
            if line.contains("turned off") {
                if offAt == nil { offAt = t }
            } else if let off = offAt {
                offAt = nil
                if t.timeIntervalSince(off) >= minSpanSeconds {
                    out.append(AwaySpan(start: off, end: t, reason: "pmset"))
                }
            }
        }
        return out
    }
}
