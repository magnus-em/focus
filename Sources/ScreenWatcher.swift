import AppKit
import CloudKit
import EventKit
import FoundationModels
import FocusCore
import ScreenCaptureKit
import Vision

/// What the frontmost window showed over a stretch of time. Device-local;
/// screenshots and recognized text are never stored, only title + summary.
struct ScreenSpan: Codable, Equatable, Identifiable {
    var start: Date
    var end: Date
    var app: String
    var bundleID: String
    var title: String
    var summary: String
    var category: String?
    /// Keyboard/mouse in use at some snapshot in this span (nil in old data).
    var active: Bool?
    var id: Date { start }
}

/// Every 15s (and on every app switch) while you're at the Mac: capture the frontmost window, read it
/// with Vision, label it (your past choices first, then the on-device Apple
/// Intelligence model), and let `ScreenCoach` suggest a backdated switch.
@MainActor
final class ScreenWatcher: ObservableObject {
    static let shared = ScreenWatcher()

    @Published private(set) var spans: [ScreenSpan] = []
    @Published private(set) var status = "Off"

    static let interval: TimeInterval = 15
    private static let keepDays = 30
    /// Never captured; logged as "Private".
    static let privateApps: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.MobileSMS", "com.apple.mail",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.dashlane.dashlanephonefinal",
        "org.torproject.torbrowser", "com.apple.FaceTime",
    ]
    private static let ignoredApps: Set<String> = [
        "com.magnus.focus", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ]

    /// Life categories done away from the Mac: while one runs the screen says
    /// nothing about what you're doing, so watching pauses.
    static let offScreenCategories: Set<String> = ["Sleep", "Meals", "Exercise", "Commute", "Chores"]
    /// Set by `ScreenCoach`: the running category, nil when nothing runs.
    var runningCategory: () -> String? = { nil }

    var onSample: ((ScreenSample) -> Void)?
    private(set) var samples: [ScreenSample] = []
    private var settings: AppSettings?
    private var tick: Timer?
    private var busy = false
    private var cache: [String: (category: String?, summary: String)] = [:]
    /// The small model flips between neighbors (Math/Reading) on the same
    /// window; a window's label only changes after 3 disagreements in a row.
    private var windowLabel: [String: (category: String, against: Int)] = [:]
    private var unsavedSamples = 0
    private var lastSampleAt = Date.distantPast
    private var lastSampled = ""
    private var titleWatch: Timer?
    private var otherScreensReadAt: [String: Date] = [:]
    private var activationObserver: NSObjectProtocol?
    /// Study notes per activity block, keyed by block start.
    @Published private(set) var activityNotes: [Date: ActivityNotes] = [:]
    private var noting = false
    /// Distinct page text from the last few hours, in memory only: the notes
    /// are written from it and it's never saved.
    private var pageTexts: [PageText] = []

    struct ActivityNotes: Codable {
        var title: String
        var bullets: [String]
        var updatedAt: Date
        /// Newest page text already folded into the notes.
        var textThrough: Date
    }

    private struct PageText {
        let date: Date
        let window: String
        let text: String
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screen.json")
    }()

    /// iPhone/iPad app opens and screen-broadcast blocks, from iCloud.
    @Published private(set) var deviceActivities: [DeviceActivity] = []
    private var devicePoll: Timer?
    private var devicesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("devices.json") }
    private static let deviceTokenKey = "deviceActivityToken"

    private var notesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("screen-notes.json") }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ScreenSpan].self, from: data) {
            spans = saved
        }
        if let data = try? Data(contentsOf: devicesURL),
           let saved = try? JSONDecoder().decode([DeviceActivity].self, from: data) {
            deviceActivities = saved
        }
        if let data = try? Data(contentsOf: notesURL),
           let saved = try? JSONDecoder().decode([Date: ActivityNotes].self, from: data) {
            activityNotes = saved
        }
    }

    func start(settings: AppSettings) {
        self.settings = settings
        guard tick == nil else { return }
        if settings.screenWatch, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        tick = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        devicePoll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollDevices() }
        }
        Task { await pollDevices() }
        // A new tab or document in the same app doesn't activate anything;
        // window titles are cheap to read, so check them between ticks.
        titleWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, Date().timeIntervalSince(self.lastSampleAt) > 4,
                      let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
                      let title = Self.frontTitle(pid: app.processIdentifier),
                      "\(bundle)|\(title)" != self.lastSampled else { return }
                await self.sample()
            }
        }
        // Catch app switches right away instead of waiting for the next tick.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    guard let self, Date().timeIntervalSince(self.lastSampleAt) > 3 else { return }
                    await self.sample()
                }
            }
        }
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func spans(from: Date, to: Date) -> [ScreenSpan] {
        spans.filter { $0.end > from && $0.start < to }
    }

    static var modelAvailable: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    // MARK: - Sampling

    private func sample() async {
        guard let settings, settings.screenWatch else { status = "Off"; return }
        guard !busy else { return }
        guard !PresenceMonitor.shared.isAway else { status = "Paused while you're away"; return }
        let idle = PresenceMonitor.idleSeconds
        guard idle < 300 else { status = "Paused, no keyboard or mouse for 5 min"; return }
        // During Chores etc. a lit screen says nothing, but hands on the
        // keyboard/mouse mean you're back, so watch (and suggest) again.
        if let c = runningCategory(), Self.offScreenCategories.contains(c), idle > 30 {
            status = "Paused during \(c) until you use the Mac"
            return
        }
        guard CGPreflightScreenCaptureAccess() else { status = "Needs Screen Recording permission"; return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !Self.ignoredApps.contains(bundle) else { return }
        let appName = app.localizedName ?? bundle
        let now = Date()

        if Self.privateApps.contains(bundle) {
            record(ScreenSample(date: now, app: appName, bundleID: bundle, title: "", summary: "Private", category: nil,
                                active: idle < 90))
            return
        }

        busy = true
        lastSampleAt = now
        defer { busy = false }
        // Other monitors' windows are re-read at most once a minute each.
        otherScreensReadAt = otherScreensReadAt.filter { now.timeIntervalSince($0.value) < 3600 }
        let recentOthers = Set(otherScreensReadAt.filter { now.timeIntervalSince($0.value) < 60 }.keys)
        guard let capture = await Self.captureWindows(pid: app.processIdentifier, skipOthers: recentOthers) else { return }
        let shot = capture.front
        let skip = Self.chromeFraction(shot, bundle: bundle)
        let text = await Task.detached(priority: .utility) { Self.recognizeText(shot.image, skipTop: skip) }.value
        keepPageText(text, window: shot.title.isEmpty ? appName : "\(appName): \(shot.title)", at: now)
        for (otherApp, other, otherBundle) in capture.others {
            let key = "\(otherApp): \(other.title)"
            otherScreensReadAt[key] = now
            let otherSkip = Self.chromeFraction(other, bundle: otherBundle)
            let otherText = await Task.detached(priority: .utility) { Self.recognizeText(other.image, skipTop: otherSkip) }.value
            keepPageText(otherText, window: "\(key) (other screen)", at: now)
        }
        let (category, summary) = await classify(app: appName, bundle: bundle, title: shot.title, text: text)
        status = Self.modelAvailable ? "Watching" : "Watching · Apple Intelligence off, learning from your choices only"
        lastSampled = "\(bundle)|\(shot.title)"
        let learned = category != nil && !Self.isGeneric(title: shot.title, app: appName)
            && Self.memory[Self.memoryKey(bundle: bundle, title: shot.title)] == category
        record(ScreenSample(date: now, app: appName, bundleID: bundle, title: shot.title,
                            summary: summary, category: category, active: PresenceMonitor.idleSeconds < 90,
                            learned: learned))
    }

    private func record(_ s: ScreenSample) {
        samples.append(s)
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }

        let end = s.date.addingTimeInterval(Self.interval)
        if var last = spans.last, last.bundleID == s.bundleID, last.title == s.title, last.category == s.category,
           s.date.timeIntervalSince(last.end) < Self.interval {
            last.end = end
            last.summary = s.summary
            last.active = (last.active ?? false) || s.active
            spans[spans.count - 1] = last
        } else {
            if let last = spans.last, last.end > s.date { spans[spans.count - 1].end = s.date }
            spans.append(ScreenSpan(start: s.date, end: end, app: s.app, bundleID: s.bundleID,
                                    title: s.title, summary: s.summary, category: s.category, active: s.active))
        }
        unsavedSamples += 1
        if unsavedSamples >= 4 { save() }
        onSample?(s)
        Task { await updateNotes() }
    }

    /// After sleep, lid close, lock or display off the old evidence is stale.
    func resetEvidence() {
        samples.removeAll()
    }

    func save() {
        unsavedSamples = 0
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86400)
        spans.removeAll { $0.end < cutoff }
        if let data = try? JSONEncoder().encode(spans) { try? data.write(to: fileURL, options: .atomic) }
        activityNotes = activityNotes.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(activityNotes) { try? data.write(to: notesURL, options: .atomic) }
    }

    // MARK: - iPhone / iPad

    private func pollDevices() async {
        let d = UserDefaults.standard
        let token = d.data(forKey: Self.deviceTokenKey).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        guard let (changes, newToken) = try? await DeviceActivityCloud.changes(since: token) else { return }
        if let newToken, let data = try? NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true) {
            d.set(data, forKey: Self.deviceTokenKey)
        }
        guard !changes.isEmpty else { return }
        var byID = Dictionary(deviceActivities.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for var c in changes {
            if c.kind == .open, c.category == nil { c.category = await categoryForApp(c.app, device: c.device) }
            byID[c.id] = c
        }
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86400)
        deviceActivities = byID.values.filter { $0.date > cutoff }.sorted { $0.date < $1.date }
        if let data = try? JSONEncoder().encode(deviceActivities) { try? data.write(to: devicesURL, options: .atomic) }
    }

    private func categoryForApp(_ app: String, device: String) async -> String? {
        let candidates = candidateCategories()
        if let known = Self.memory[Self.memoryKey(bundle: "ios", title: app)], candidates.contains(known) { return known }
        guard #available(macOS 26.0, *), Self.modelAvailable else { return nil }
        return await ScreenLabeler.classify(app: app, title: "\(app) app on an \(device)", text: "", categories: candidates)?.0
    }

    /// App opens become spans that last until the next open/close on that
    /// device (at most 30 min); runs of the same app form one block.
    private func deviceBlocks(from: Date, to: Date) -> [ScreenActivity] {
        var out: [ScreenActivity] = []
        let inRange = deviceActivities.filter { ($0.end ?? $0.date) > from && $0.date < to }
        for b in inRange where b.kind == .block {
            let end = b.end ?? b.date
            let span = ScreenSpan(start: b.date, end: end, app: "\(b.device) screen", bundleID: "ios:\(b.device):screen",
                                  title: "", summary: b.title, category: b.category)
            var a = ScreenActivity(start: b.date, end: end, category: b.category, spans: [span])
            a.device = b.device
            a.deviceNotes = ActivityNotes(title: b.title, bullets: b.bullets, updatedAt: end, textThrough: end)
            out.append(a)
        }
        for device in Set(inRange.map(\.device)) {
            let events = deviceActivities.filter { $0.device == device && $0.kind != .block }
            for (i, e) in events.enumerated() where e.kind == .open && e.date < to {
                let next = i + 1 < events.count ? events[i + 1].date : Date()
                let end = min(next, e.date.addingTimeInterval(30 * 60))
                guard end > from, end.timeIntervalSince(e.date) >= 20 else { continue }
                let span = ScreenSpan(start: e.date, end: end, app: "\(device) · \(e.app)", bundleID: "ios:\(device):\(e.app)",
                                      title: "", summary: e.app, category: e.category)
                if var last = out.last, last.device == device, last.spans.last?.bundleID == span.bundleID,
                   e.date.timeIntervalSince(last.end) < 120 {
                    last.end = end
                    last.spans.append(span)
                    out[out.count - 1] = last
                } else {
                    var a = ScreenActivity(start: e.date, end: end, category: e.category, spans: [span])
                    a.device = device
                    out.append(a)
                }
            }
        }
        return out
    }

    // MARK: - Activities

    /// Spans grouped into stretches of one kind of work. Blips under a minute
    /// between two spans of the same category don't split a block.
    /// Mac blocks and iPhone/iPad blocks, oldest first.
    /// While an iPad screen-notes block runs, Mac snapshots with no keyboard or
    /// mouse input are just a lit screen nobody's looking at: drop them so the
    /// same time isn't logged twice. Used-at-the-same-time stays.
    func activities(from: Date, to: Date) -> [ScreenActivity] {
        let devices = deviceBlocks(from: from, to: to)
        let watched = devices.filter { $0.deviceNotes != nil }.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
        let mac = macActivities(from: from, to: to, excluding: watched)
        return (mac + devices).sorted { $0.start < $1.start }
    }

    private func macActivities(from: Date, to: Date, excluding watched: [DateInterval] = []) -> [ScreenActivity] {
        let list = spans(from: from, to: to).sorted { $0.start < $1.start }.filter { s in
            s.active != false || !watched.contains { $0.intersects(DateInterval(start: s.start, end: max(s.end, s.start))) }
        }
        var smoothed = list.map(\.category)
        if list.count >= 3 {
            for i in 1..<(list.count - 1) {
                let d = list[i].end.timeIntervalSince(list[i].start)
                if d < 60, smoothed[i - 1] == smoothed[i + 1], smoothed[i] != smoothed[i - 1] { smoothed[i] = smoothed[i - 1] }
            }
        }
        var out: [ScreenActivity] = []
        for (i, span) in list.enumerated() {
            let c = smoothed[i]
            if var last = out.last, last.category == c, span.start.timeIntervalSince(last.end) < 5 * 60 {
                last.end = max(last.end, span.end)
                last.spans.append(span)
                out[out.count - 1] = last
            } else {
                out.append(ScreenActivity(start: span.start, end: span.end, category: c, spans: [span]))
            }
        }
        return out
    }

    /// Block edges can move a little as new snapshots smooth older ones, so
    /// notes keyed anywhere inside the block still belong to it.
    func notes(for a: ScreenActivity) -> ActivityNotes? {
        if let n = a.deviceNotes { return n }
        if a.device != nil { return nil }
        if let n = activityNotes[a.start] { return n }
        return activityNotes.filter { $0.key >= a.start && $0.key < a.end }.min { $0.key < $1.key }?.value
    }

    func name(for a: ScreenActivity) -> String { notes(for: a)?.title ?? a.topTitle }

    /// Distinct page text read since `date` (in memory only; the prompt log
    /// copies it out on purpose).
    func pages(since date: Date) -> [(date: Date, window: String, text: String)] {
        pageTexts.filter { $0.date >= date }.map { ($0.date, $0.window, $0.text) }
    }

    private func keepPageText(_ text: String, window: String, at date: Date) {
        guard text.count >= 40 else { return }
        if pageTexts.suffix(40).contains(where: { $0.window == window && $0.text == text }) { return }
        pageTexts.append(PageText(date: date, window: window, text: text))
        pageTexts.removeAll { date.timeIntervalSince($0.date) > 4 * 3600 }
    }

    /// One model call per sample at most: first a just-finished block gets its
    /// last pages folded in, then the live block every 90s as new pages appear.
    private func updateNotes() async {
        guard !noting, #available(macOS 26.0, *), Self.modelAvailable else { return }
        let now = Date()
        let blocks = macActivities(from: now.addingTimeInterval(-4 * 3600), to: now)
            .filter { $0.end.timeIntervalSince($0.start) >= 90 }
        func fresh(_ b: ScreenActivity) -> [PageText] {
            let since = notes(for: b)?.textThrough ?? .distantPast
            return pageTexts.filter { $0.date >= b.start && $0.date < b.end && $0.date > since }
        }
        let live = blocks.last.flatMap { now.timeIntervalSince($0.end) < 60 ? $0 : nil }
        let target = blocks.first { $0.id != live?.id && !fresh($0).isEmpty }
            ?? live.flatMap { b in
                let last = notes(for: b)?.updatedAt ?? .distantPast
                return !fresh(b).isEmpty && now.timeIntervalSince(last) >= 90 ? b : nil
            }
        guard let b = target else { return }
        let pages = fresh(b)
        noting = true
        defer { noting = false }
        let previous = notes(for: b)
        if let (title, bullets) = await ScreenLabeler.studyNotes(
            category: b.category ?? "Unlabeled", windows: b.distinctTitles,
            previous: previous.map { ($0.title, $0.bullets) },
            pages: pages.map { ($0.window, $0.text) }
        ) {
            for k in activityNotes.keys where k >= b.start && k < b.end { activityNotes[k] = nil }
            activityNotes[b.start] = ActivityNotes(title: title, bullets: bullets, updatedAt: now,
                                                   textThrough: pages.map(\.date).max() ?? now)
        }
    }

    // MARK: - Capture + OCR

    private struct Shot: @unchecked Sendable {
        let image: CGImage
        let title: String
        let heightPoints: CGFloat
    }

    /// Their tab strip and bookmarks bar OCR first and filled the 1500-char
    /// budget (godbolt read as "Ask Gemini / 3231 Study Guides / …" → Math).
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]
    private static let browserChromePoints: CGFloat = 120

    private struct Capture {
        let front: Shot
        /// Top window on each other display: context for notes, not the label.
        let others: [(app: String, shot: Shot, bundle: String)]
    }

    private static func frontTitle(pid: pid_t) -> String? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.first {
            ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == pid
        }.map { $0[kCGWindowName as String] as? String ?? "" }
    }

    private static func captureWindows(pid: pid_t, skipOthers: Set<String>) async -> Capture? {
        // CGWindowList is front-to-back; SCShareableContent isn't ordered.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows: [(id: CGWindowID, pid: pid_t, bounds: CGRect, name: String)] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let owner = w[kCGWindowOwnerPID as String] as? Int32,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  b.width > 200, b.height > 150 else { return nil }
            return (id, owner, b, w[kCGWindowName as String] as? String ?? "")
        }
        guard let front = windows.first(where: { $0.pid == pid }),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let frontShot = await shoot(front.id, in: content, fallbackTitle: front.name) else { return nil }

        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        let displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        let center = { (r: CGRect) in CGPoint(x: r.midX, y: r.midY) }
        var others: [(String, Shot, String)] = []
        for d in displays where !d.contains(center(front.bounds)) {
            guard let top = windows.first(where: { d.contains(center($0.bounds)) }),
                  let app = NSRunningApplication(processIdentifier: top.pid),
                  let bundle = app.bundleIdentifier,
                  !privateApps.contains(bundle), !ignoredApps.contains(bundle) else { continue }
            let name = app.localizedName ?? bundle
            guard !skipOthers.contains("\(name): \(top.name)"),
                  let shot = await shoot(top.id, in: content, fallbackTitle: top.name) else { continue }
            others.append((name, shot, bundle))
        }
        return Capture(front: frontShot, others: others)
    }

    private static func shoot(_ id: CGWindowID, in content: SCShareableContent, fallbackTitle: String) async -> Shot? {
        guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let config = SCStreamConfiguration()
        // Big external monitors: keep enough pixels for small text to OCR.
        let scale = min(2, 3600 / max(window.frame.width, window.frame.height))
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
        ) else { return nil }
        return Shot(image: image, title: window.title ?? fallbackTitle, heightPoints: window.frame.height)
    }

    nonisolated private static func recognizeText(_ image: CGImage, skipTop: CGFloat = 0) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .filter { $0.boundingBox.maxY <= 1 - skipTop }
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(2500))
    }

    nonisolated private static func chromeFraction(_ shot: Shot, bundle: String?) -> CGFloat {
        guard let bundle, browsers.contains(bundle), shot.heightPoints > 300 else { return 0 }
        return browserChromePoints / shot.heightPoints
    }

    // MARK: - Classification

    /// "ChatGPT", "Claude", "": one window for every chat, so a learned label
    /// would stick to all of them.
    nonisolated static func isGeneric(title: String, app: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || t == app.lowercased() || app.lowercased().hasPrefix(t)
    }

    nonisolated static func memoryKey(bundle: String, title: String) -> String {
        bundle + "|" + title.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static let memoryDefaultsKey = "screenMemory"

    static var memory: [String: String] {
        UserDefaults.standard.dictionary(forKey: memoryDefaultsKey) as? [String: String] ?? [:]
    }

    /// The user's answer for these windows beats the model next time.
    static func learn(_ keys: Set<String>, as category: String) {
        var m = memory
        for k in keys { m[k] = category }
        if m.count > 800 { m = Dictionary(uniqueKeysWithValues: m.shuffled().prefix(800).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(m, forKey: memoryDefaultsKey)
    }

    private func classify(app: String, bundle: String, title: String, text: String) async -> (String?, String) {
        let fallbackSummary = title.isEmpty ? app : "\(app): \(title)"
        let candidates = candidateCategories()
        let generic = Self.isGeneric(title: title, app: app)
        if !generic, let known = Self.memory[Self.memoryKey(bundle: bundle, title: title)], candidates.contains(known) {
            return (known, cache[cacheKey(bundle, title, text)]?.summary ?? fallbackSummary)
        }
        let key = cacheKey(bundle, title, text)
        if let hit = cache[key] { return hit }
        guard #available(macOS 26.0, *), Self.modelAvailable, !text.isEmpty || !title.isEmpty else {
            return (nil, fallbackSummary)
        }
        var result = await ScreenLabeler.classify(app: app, title: title, text: text, categories: candidates)
            ?? (nil, fallbackSummary)
        let window = Self.memoryKey(bundle: bundle, title: title)
        if let c = result.0, !generic {
            if let held = windowLabel[window], held.category != c, candidates.contains(held.category) {
                if held.against + 1 >= 3 {
                    windowLabel[window] = (c, 0)
                } else {
                    windowLabel[window] = (held.category, held.against + 1)
                    result.0 = held.category
                }
            } else {
                windowLabel[window] = (c, 0)
            }
            if windowLabel.count > 300 { windowLabel.removeAll() }
        }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private func cacheKey(_ bundle: String, _ title: String, _ text: String) -> String {
        "\(bundle)|\(title)|\(text.prefix(300).hashValue)"
    }

    /// Categories you could plausibly be doing on a screen.
    private func candidateCategories() -> [String] {
        return (settings?.tags ?? []).filter { !FocusCategories.notFromScreen.contains($0) }
    }
}

struct ScreenActivity: Identifiable {
    var start: Date
    var end: Date
    var category: String?
    var spans: [ScreenSpan]
    /// nil = this Mac; "iPhone" / "iPad" otherwise.
    var device: String? = nil
    /// Notes written on the device (screen broadcast).
    var deviceNotes: ScreenWatcher.ActivityNotes? = nil
    var id: String { "\(device ?? "mac")-\(start.timeIntervalSince1970)" }
    var minutes: Double { end.timeIntervalSince(start) / 60 }

    /// Most frequent first; ties keep first-seen order so redraws don't reshuffle.
    private func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for v in values where !v.isEmpty {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        return order.enumerated().sorted {
            counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset
        }.map(\.element)
    }
    var distinctSummaries: [String] { Array(ranked(spans.map(\.summary)).prefix(10)) }
    var distinctTitles: [String] { Array(ranked(spans.map { $0.title.isEmpty ? $0.app : "\($0.app): \($0.title)" }).prefix(6)) }
    var apps: [String] { ranked(spans.map(\.app)) }
    var topTitle: String { distinctTitles.first ?? "Unknown" }
}

struct ScreenSample {
    let date: Date
    let app: String
    let bundleID: String
    let title: String
    let summary: String
    let category: String?
    /// Keyboard/mouse used in the last 90s: only these count as evidence for
    /// a suggestion (a PDF left open while you walk away isn't "doing Math").
    var active = true
    /// Label came from your own earlier answer, not the model.
    var learned = false
    var memoryKey: String { ScreenWatcher.memoryKey(bundle: bundleID, title: title) }
}

// MARK: - Suggestions

/// Suggests switching when the screen has shown another category for a few
/// minutes, backdated to when it started. Never switches on its own.
@MainActor
final class ScreenCoach {
    nonisolated(unsafe) static var shared: ScreenCoach?

    private let watcher = ScreenWatcher.shared
    private let timer: TimerManager
    private let settings: AppSettings
    private let days: DayStore
    private let panel = AwayPanel()
    private var snoozed: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    static let acceptedKey = "screenSuggest.accepted"
    static let declinedKey = "screenSuggest.declined"

    init(timer: TimerManager, settings: AppSettings, days: DayStore) {
        self.timer = timer
        self.settings = settings
        self.days = days
        watcher.onSample = { [weak self] _ in self?.consider() }
        watcher.runningCategory = { [weak timer] in
            guard let timer, timer.isActive, !timer.isOnBreak, !timer.currentLabel.isEmpty else { return nil }
            return timer.currentLabel
        }
        watcher.start(settings: settings)
        ClassCalendar.shared.start()
        let reset: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.watcher.resetEvidence()
                self?.panel.dismiss()
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: reset),
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: reset),
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: reset),
        ]
    }

    /// AwayCoach checks this from main-thread timers that aren't actor-annotated.
    nonisolated var isBusy: Bool { MainActor.assumeIsolated { panel.isBusy } }

    private struct Run {
        let category: String
        let start: Date
        let keys: Set<String>
        let summary: String
    }

    /// The model labeled the window, or you did earlier: your own label needs
    /// less proof, so a window you've answered for before is suggested in 45s.
    private static let learnedRunSeconds: TimeInterval = 45

    /// Trailing stretch where ≥ 80% of active samples say the same category.
    /// Two misses in a row, a 60s hole (sleep, away, paused) or the moment you
    /// picked the current category ends it: what was on screen before your
    /// own choice isn't evidence against it.
    private func trailingRun(notBefore floor: Date?) -> Run? {
        let samples = watcher.samples
        guard let last = samples.last, last.active, let c = last.category else { return nil }
        var start = last.date, hits = 0, total = 0, missStreak = 0
        var keys: Set<String> = []
        var allLearned = true
        var newer = last.date
        for s in samples.reversed() {
            if newer.timeIntervalSince(s.date) > 60 { break }
            if let floor, s.date < floor { break }
            newer = s.date
            guard s.active else { continue }
            total += 1
            if s.category == c {
                hits += 1; missStreak = 0; start = s.date
                if !ScreenWatcher.isGeneric(title: s.title, app: s.app) { keys.insert(s.memoryKey) }
                allLearned = allLearned && s.learned
            } else {
                missStreak += 1
                if missStreak >= 2 { total -= 2; break }
            }
        }
        let needed = allLearned ? Self.learnedRunSeconds : Double(settings.screenSuggestMinutes) * 60
        guard hits >= (allLearned ? 3 : 4), Double(hits) / Double(max(total, 1)) >= 0.8,
              last.date.timeIntervalSince(start) >= needed else { return nil }
        return Run(category: c, start: start, keys: keys, summary: last.summary)
    }

    private func consider() {
        guard settings.screenSuggest, days.isDayStarted, !panel.isBusy,
              !(AwayCoach.shared?.isBusy ?? false) else { return }
        // In class you're in Class, whatever the screen shows.
        if timer.isActive, !timer.isOnBreak, timer.currentLabel == "Class" { return }
        // "Still SWE" on the class card means you're not in it (10/13: kept
        // SWE on all four), so the screen gets its say again.
        if let lecture = ClassCalendar.shared.currentClass(), !classDeclined.contains(Self.classKey(lecture)) {
            suggestClass(lecture)
            return
        }
        guard
              let run = trailingRun(notBefore: timer.isActive ? timer.sessionStartTime : nil) else { return }
        if timer.isActive && !timer.isRunning { return }
        let running: String? = timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : nil
        guard running != run.category, (snoozed[run.category] ?? .distantPast) < Date() else { return }

        let minutes = Date().timeIntervalSince(run.start) / 60
        let m = AwayPromptModel(
            icon: "eye",
            title: "Looks like \(run.category)",
            subtitle: "since \(run.start.formatted(date: .omitted, time: .shortened)) · \(Int(minutes))m on screen",
            question: run.summary,
            keep: running.map { "Still \($0)" },
            options: [run.category], tags: settings.tags
        )
        let logID = PromptLog.screenPrompt(model: m, running: running, suggested: run.category, since: run.start,
                                           samples: watcher.samples, pages: watcher.pages(since: run.start))
        m.onPick = { [weak self] label in
            guard let self else { return }
            PromptLog.answer(logID, "switched to \(label ?? "Break")")
            if let label {
                self.timer.switchTo(label, at: run.start)
                if !FocusCategories.isLife(label) { ScreenWatcher.learn(run.keys, as: label) }
            } else {
                self.timer.startManualBreak(minutes: 0, at: run.start)
            }
            Self.bump(Self.acceptedKey)
            self.panel.dismiss()
        }
        m.onKeep = { [weak self] in
            guard let self else { return }
            PromptLog.answer(logID, "kept \(running ?? "nothing")")
            // Only focus-vs-focus answers say what a window is (Compiler
            // Explorer is SWE, not Math). "Still SWE" over Shortcuts or YouTube
            // means a side trip, which the distraction log counts instead.
            if let running, running != "Break", !FocusCategories.isLife(running), !FocusCategories.isLife(run.category) {
                ScreenWatcher.learn(run.keys, as: running)
            }
            self.decline(run.category)
        }
        panel.show(m)
        let close = m.onClose
        m.onClose = { [weak self] in
            PromptLog.answer(logID, "closed")
            self?.decline(run.category)
            close?()
        }
    }

    private var classPrompted: Set<String> = []
    private var classDeclined: Set<String> = []

    /// Title + start, not the event id: the same class on two calendars
    /// (Google + Yale) showed the card twice.
    private static func classKey(_ e: EKEvent) -> String {
        "\(e.title ?? "")@\(Int(e.startDate.timeIntervalSince1970))"
    }

    /// One card per calendar class: switch to Class from when it started.
    private func suggestClass(_ lecture: EKEvent) {
        let key = Self.classKey(lecture)
        guard !classPrompted.contains(key), settings.tags.contains("Class") else { return }
        classPrompted.insert(key)
        let running: String? = timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : nil
        let clock = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let m = AwayPromptModel(
            icon: "graduationcap",
            title: "In class: \(lecture.title ?? "Class")",
            subtitle: "\(clock(lecture.startDate)) – \(clock(lecture.endDate)) · from your calendar",
            question: "Track this as Class? It starts from \(clock(lecture.startDate)).",
            keep: running.map { "Still \($0)" },
            options: ["Class"], tags: settings.tags
        )
        let logID = PromptLog.screenPrompt(model: m, running: running, suggested: "Class", since: lecture.startDate,
                                           samples: [], pages: [], reason: "calendar event: \(lecture.title ?? "")")
        m.onPick = { [weak self] label in
            guard let self else { return }
            PromptLog.answer(logID, "switched to \(label ?? "Break")")
            if let label { self.timer.switchTo(label, at: lecture.startDate) } else { self.timer.startManualBreak(minutes: 0, at: lecture.startDate) }
            self.panel.dismiss()
        }
        m.onKeep = { [weak self] in
            PromptLog.answer(logID, "kept \(running ?? "nothing")")
            self?.classDeclined.insert(key)
            self?.panel.dismiss()
        }
        panel.show(m)
        let close = m.onClose
        m.onClose = {
            PromptLog.answer(logID, "closed")
            close?()
        }
    }

    private func decline(_ category: String) {
        snoozed[category] = Date().addingTimeInterval(20 * 60)
        Self.bump(Self.declinedKey)
        panel.dismiss()
    }

    private static func bump(_ key: String) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}

// MARK: - Prompt log

/// Every switch card with what it was decided from (snapshots and the page
/// text read during the run), and what you answered, as JSON lines in
/// `Focus/prompt-log.jsonl` (14 days). Meant to be handed to Claude to tune
/// the rules. This is the one place page text is written to disk.
enum PromptLog {
    struct Snapshot: Codable {
        let at: Date
        let app: String
        let title: String
        let summary: String
        let category: String?
        let active: Bool
    }

    struct Page: Codable {
        let at: Date
        let window: String
        let text: String
    }

    struct Line: Codable {
        let id: UUID
        let at: Date
        var card: String?
        var subtitle: String?
        var shownText: String?
        var running: String?
        var suggested: String?
        var since: Date?
        var reason: String?
        var snapshots: [Snapshot]?
        var pages: [Page]?
        /// Set on the follow-up line for the same id.
        var answer: String?
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prompt-log.jsonl")
    }()

    @discardableResult
    static func screenPrompt(model m: AwayPromptModel, running: String?, suggested: String, since: Date,
                             samples: [ScreenSample], pages: [(date: Date, window: String, text: String)],
                             reason: String = "screen") -> UUID {
        let id = UUID()
        let context = since.addingTimeInterval(-3 * 60)
        append(Line(
            id: id, at: Date(), card: m.title, subtitle: m.subtitle, shownText: m.question,
            running: running, suggested: suggested, since: since, reason: reason,
            snapshots: samples.filter { $0.date >= context }.map {
                Snapshot(at: $0.date, app: $0.app, title: $0.title, summary: $0.summary, category: $0.category, active: $0.active)
            },
            pages: pages.suffix(12).map { Page(at: $0.date, window: $0.window, text: String($0.text.prefix(1500))) }
        ))
        return id
    }

    static func answer(_ id: UUID, _ answer: String) {
        append(Line(id: id, at: Date(), answer: answer))
    }

    private static func append(_ line: Line) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var data = try? enc.encode(line) else { return }
        data.append(0x0A)
        prune()
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static var prunedAt = Date.distantPast

    private static func prune() {
        guard Date().timeIntervalSince(prunedAt) > 6 * 3600, let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        prunedAt = Date()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let kept = raw.split(separator: "\n").filter {
            guard let l = try? dec.decode(Line.self, from: Data($0.utf8)) else { return false }
            return l.at >= cutoff
        }
        try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }
}
