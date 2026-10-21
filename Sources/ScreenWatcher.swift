import AppKit
import NaturalLanguage
import CloudKit
import Combine
import EventKit
import FoundationModels
import FocusCore
import ScreenCaptureKit
import Vision

/// What the frontmost window showed over a stretch of time. Device-local;
/// Review images are retained separately in the bounded local evidence store.
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
    /// Where the label came from: "you" (your earlier answer), "model",
    /// "held" (kept by window stickiness), "focus" (time in Focus). nil in old data.
    var source: String?
    var reason: String?
    var uncertain: Bool?
    var testMode: Bool? = nil
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
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
    ]
    /// Time in Focus itself is logged (not read: its own text would feed the
    /// model "SWE 1:58:50"), labeled with what's running, and never counts as
    /// evidence for a switch.
    static let ownBundle = "com.magnus.focus"

    /// Apps you've told it to skip (ATV Remote, a music player): never
    /// sampled, and dropped from the log, notes and off-task counts, past ones too.
    static let userIgnoredKey = "screenIgnoredApps"
    static var userIgnored: [String: String] {
        UserDefaults.standard.dictionary(forKey: userIgnoredKey) as? [String: String] ?? [:]
    }
    func setIgnored(_ bundle: String, name: String, _ on: Bool) {
        var m = Self.userIgnored
        m[bundle] = on ? name : nil
        UserDefaults.standard.set(m, forKey: Self.userIgnoredKey)
        if on {
            resetEvidence()
            ScreenEvidenceStore.shared.delete(bundle: bundle)
        }
        objectWillChange.send()
    }

    /// What the last snapshot read, for Settings → Screen → "What it sees".
    struct Snapshot {
        var date: Date
        var app: String
        var bundle: String
        var title: String
        var text: String
        var others: [(window: String, text: String)]
        var category: String?
        var summary: String
        var source: String
        var active: Bool
        var seconds: Double
        var reason: String = ""
        var uncertain = false
    }
    @Published private(set) var lastSnapshot: Snapshot?
    /// Why the coach did or didn't show a card after the last snapshot.
    @Published var coachStatus = ""
    private var labelSource = ""
    private var labelReason = ""
    private var labelUncertain = false
    private var taskContext = LocalTaskContext()

    /// Life categories done away from the Mac: while one runs the screen says
    /// nothing about what you're doing, so watching pauses.
    static let offScreenCategories: Set<String> = ["Sleep", "Meals", "Exercise", "Commute", "Chores"]
    /// Set by `ScreenCoach`: the running category, nil when nothing runs.
    var runningCategory: () -> String? = { nil }

    struct PracticeObservation {
        let at: Date
        let slug: String?
    }
    let practiceObservations = PassthroughSubject<PracticeObservation, Never>()
    var onSample: ((ScreenSample) -> Void)?
    private(set) var samples: [ScreenSample] = []
    private var settings: AppSettings?
    private var tick: Timer?
    private var busy = false
    private var sampleGeneration = 0
    private var journalWindowID: CGWindowID?
    private var journalWindowChangedAt = Date()
    private var watchSetting: AnyCancellable?
    /// OCR sometimes drops a space in a chat's title ("Activitycategory
    /// naming"), splitting one chat into two windows; the spaced spelling wins.
    private var chatTitles: [String: String] = [:]

    private func canonicalChatTitle(_ t: String, bundle: String) -> String {
        let key = bundle + "|" + t.lowercased().filter { !$0.isWhitespace }
        let spaces = { (x: String) in x.filter(\.isWhitespace).count }
        if let known = chatTitles[key], spaces(known) >= spaces(t) { return known }
        if chatTitles.count > 300 { chatTitles.removeAll() }
        chatTitles[key] = t
        return t
    }
    /// What the watcher is doing right now, for the live line on the Dashboard.
    @Published private(set) var stage = ""
    var nextSnapshotAt: Date? { tick?.fireDate }
    private struct CachedLabel {
        var category: String?
        var summary: String
        var reason: String
        var uncertain: Bool
    }
    private var cache: [String: CachedLabel] = [:]
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
        /// The block these notes were written for. Blocks' edges move as
        /// snapshots smooth, so notes are matched by overlap, not by key.
        var start: Date?
        var end: Date?
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
        CoachEpisodeStore.shared.start()
        guard tick == nil else { return }
        watchSetting = settings.$screenWatch.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            if !enabled { self?.resetEvidence(); ScreenJournalStore.shared.invalidate() }
        }
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
            MainActor.assumeIsolated {
                self?.journalWindowID = nil
                self?.journalWindowChangedAt = Date()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in
                    guard let self, Date().timeIntervalSince(self.lastSampleAt) > 3 else { return }
                    await self.sample()
                }
            }
        }
    }

    // MARK: - Your checks

    /// ✓/✗ on activity blocks: the accuracy score, and labels to learn from.
    struct BlockCheck: Codable {
        var start: Date
        var end: Date
        var said: String?
        var right: Bool
        var actual: String?
        var at: Date
        var disposition: String? = nil
        var testMode: Bool? = nil
    }
    @Published private(set) var checks: [BlockCheck] = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/screen-checks.json")
        return (try? JSONDecoder().decode([BlockCheck].self, from: Data(contentsOf: url))) ?? []
    }()
    private var checksURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("screen-checks.json") }

    var checkChoices: [String] { (settings?.tags ?? []).filter { !FocusCategories.notFromScreen.contains($0) } }
    var reviewChoices: [String] { settings?.tags ?? [] }

    func check(for a: ScreenActivity) -> BlockCheck? {
        checks.last { min($0.end, a.end) > max($0.start, a.start) }
    }

    private static func checkMode(_ activity: ScreenActivity) -> Bool? {
        let modes = activity.spans.map(\.testMode)
        guard !modes.isEmpty, let first = modes.first!, modes.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func setCheck(_ a: ScreenActivity, right: Bool, actual: String? = nil) {
        checks.removeAll { min($0.end, a.end) > max($0.start, a.start) }
        checks.append(BlockCheck(start: a.start, end: a.end, said: a.category, right: right, actual: actual, at: Date(),
                                 testMode: Self.checkMode(a)))
        checks.removeAll { $0.end < Date().addingTimeInterval(-60 * 86400) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to: checksURL, options: .atomic) }
        let label = right ? a.category : actual
        if a.device == nil, let label, !FocusCategories.notFromScreen.contains(label) {
            let keys = Set(a.spans.filter { !Self.isGeneric(title: $0.title, app: $0.app) }
                .map { Self.memoryKey(bundle: $0.bundleID, title: $0.title) })
            Self.learn(keys, as: label)
        }
    }

    func setReviewDisposition(_ a: ScreenActivity, disposition: String) {
        guard ["unsure", "mixed"].contains(disposition) else { return }
        checks.removeAll { min($0.end, a.end) > max($0.start, a.start) }
        checks.append(BlockCheck(start: a.start, end: a.end, said: a.category, right: false,
                                 actual: nil, at: Date(), disposition: disposition))
        checks.removeAll { $0.end < Date().addingTimeInterval(-60 * 86400) }
        if let data = try? JSONEncoder().encode(checks) { try? data.write(to: checksURL, options: .atomic) }
    }

    func checkScore(days: Int = 7) -> (right: Int, total: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let recent = checks.filter { $0.end > cutoff && $0.disposition == nil }
        return (recent.filter(\.right).count, recent.count)
    }

    /// `focus://screen-debug`: the last snapshot, recent samples and the coach's
    /// reasoning as JSON in `Focus/screen-debug.json`, for Claude to read.
    func dumpDebug() {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = ["episodeStatus": CoachEpisodeStore.shared.status, "episodeError": CoachEpisodeStore.shared.lastError ?? "", "episodeDryRun": CoachEpisodeStore.shared.dryRun, "journalError": ScreenJournalStore.shared.lastError ?? "", "status": status, "coach": coachStatus, "ignored": Self.userIgnored,
                                "modelError": { if #available(macOS 26.0, *) { return ScreenLabeler.lastError ?? "" }; return "" }()]
        if let x = lastSnapshot {
            d["snapshot"] = ["at": iso.string(from: x.date), "app": x.app, "bundle": x.bundle, "title": x.title,
                             "category": x.category ?? "none", "summary": x.summary, "source": x.source,
                             "active": x.active, "seconds": x.seconds, "text": x.text,
                             "reason": x.reason, "uncertain": x.uncertain,
                             "otherScreens": x.others.map { ["window": $0.window, "text": $0.text] }]
        }
        d["samples"] = samples.suffix(40).map {
            ["at": iso.string(from: $0.date), "app": $0.app, "title": $0.title, "category": $0.category ?? "none",
             "summary": $0.summary, "active": $0.active, "learned": $0.learned,
             "reason": $0.reason ?? "", "uncertain": $0.uncertain] as [String: Any]
        }
        d["memory"] = Self.memory
        d["recentTasks"] = taskContext.promptContext()
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL.deletingLastPathComponent().appendingPathComponent("screen-debug.json"))
        }
    }

    /// Apps seen in the last week, for the ignore picker.
    func recentApps() -> [(bundle: String, name: String)] {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        var seen: [String: String] = [:]
        for sp in spans where sp.end > cutoff { seen[sp.bundleID] = sp.app }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func spans(from: Date, to: Date) -> [ScreenSpan] {
        let ignored = Self.userIgnored
        return spans.filter { $0.end > from && $0.start < to && ignored[$0.bundleID] == nil }
    }

    static var modelAvailable: Bool {
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    // MARK: - Sampling

    private func sample() async {
        guard let settings, settings.screenWatch else { status = "Off"; taskContext.clear(); return }
        guard !busy else { return }
        guard !PresenceMonitor.shared.isAway else { status = "Paused while you're away"; taskContext.clear(); return }
        let idle = PresenceMonitor.idleSeconds
        guard idle < 300 else { status = "Paused, no keyboard or mouse for 5 min"; taskContext.clear(); return }
        // During Chores etc. a lit screen says nothing, but hands on the
        // keyboard/mouse mean you're back, so watch (and suggest) again.
        if let c = runningCategory(), Self.offScreenCategories.contains(c), idle > 30 {
            status = "Paused during \(c) until you use the Mac"
            return
        }
        guard CGPreflightScreenCaptureAccess() else { status = "Needs Screen Recording permission"; return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !Self.ignoredApps.contains(bundle) else { return }
        if Self.userIgnored[bundle] != nil {
            taskContext.clear()
            status = "Skipping \(app.localizedName ?? bundle) (ignored)"
            return
        }
        let appName = app.localizedName ?? bundle
        let now = Date()
        let generation = sampleGeneration
        let journalToken = ScreenJournalStore.shared.token
        let trackedAtCapture = runningCategory()

        if bundle == Self.ownBundle {
            let window = Self.frontTitle(pid: app.processIdentifier) ?? ""
            lastSampleAt = now
            lastSampled = "\(bundle)|\(window)"
            record(ScreenSample(date: now, app: "Focus", bundleID: bundle, title: window.isEmpty ? "Focus" : window,
                                summary: "Checking Focus", category: runningCategory().flatMap { $0 == "Break" ? nil : $0 },
                                active: idle < 90, source: "focus"))
            return
        }

        if Self.privateApps.contains(bundle) {
            practiceObservations.send(.init(at: now, slug: nil))
            taskContext.clear()
            record(ScreenSample(date: now, app: appName, bundleID: bundle, title: "", summary: "Private", category: nil,
                                active: idle < 90))
            return
        }

        busy = true
        lastSampleAt = now
        stage = "Capturing \(appName)"
        defer { busy = false; stage = "" }
        // Other monitors' windows are re-read at most once a minute each.
        otherScreensReadAt = otherScreensReadAt.filter { now.timeIntervalSince($0.value) < 3600 }
        let recentOthers = Set(otherScreensReadAt.filter { now.timeIntervalSince($0.value) < 60 }.keys)
        guard let capture = await Self.captureWindows(pid: app.processIdentifier, skipOthers: recentOthers) else { return }
        guard canRecordSample(generation: generation, bundle: bundle) else { return }
        let shot = capture.front
        let capturedAt = Date()
        if journalWindowID != shot.windowID {
            journalWindowID = shot.windowID
            journalWindowChangedAt = capturedAt
        }
        let focusReportAtCapture = BrowserBridge.shared.focusReport
        let browserTabAtCapture = BrowserBridge.shared.activeTab
        let windowChangedAtCapture = journalWindowChangedAt
        let skip = Self.chromeFraction(shot, bundle: bundle)
        stage = "Reading text in \(appName)"
        let includeSidebar = !Self.chatApps.contains(bundle)
        let read = await Task.detached(priority: .utility) {
            Self.recognize(shot.image, skipTop: skip, includeSidebar: includeSidebar)
        }.value
        let text = read.text
        guard canRecordSample(generation: generation, bundle: bundle) else { return }
        var title = shot.title
        if Self.chatApps.contains(bundle), Self.isGeneric(title: title, app: appName), let h = read.header,
           !Self.isGeneric(title: h, app: appName) {
            title = canonicalChatTitle(h, bundle: bundle)
        }
        let imageID = await ScreenEvidenceStore.shared.record(image: shot.image, at: now, bundle: bundle, title: title)
        guard canRecordSample(generation: generation, bundle: bundle) else { return }
        // The Chrome extension knows the tab's address; the picture doesn't.
        var url: String?
        if Self.browsers.contains(bundle), let tab = browserTabAtCapture,
           now.timeIntervalSince(tab.at) < 300, !tab.title.isEmpty, shot.title.hasPrefix(tab.title) || tab.title.hasPrefix(shot.title) {
            url = tab.url
        }
        keepPageText(text, window: title.isEmpty ? appName : "\(appName): \(title)", at: now)
        var otherTexts: [(window: String, text: String)] = []
        for (otherApp, other, otherBundle) in capture.others where Self.userIgnored[otherBundle] == nil {
            let key = "\(otherApp): \(other.title)"
            otherScreensReadAt[key] = now
            let otherSkip = Self.chromeFraction(other, bundle: otherBundle)
            let otherText = await Task.detached(priority: .utility) { Self.recognizeText(other.image, skipTop: otherSkip) }.value
            keepPageText(otherText, window: "\(key) (other screen)", at: now)
            otherTexts.append((key, otherText))
        }
        guard canRecordSample(generation: generation, bundle: bundle) else { return }
        stage = "Labeling \(title.isEmpty ? appName : title)"
        let (category, summary) = await classify(app: appName, bundle: bundle, title: title, text: text, url: url)
        guard canRecordSample(generation: generation, bundle: bundle) else { return }
        status = Self.modelAvailable ? "Watching" : "Watching · Apple Intelligence off, learning from your choices only"
        lastSampled = "\(bundle)|\(shot.title)"
        let learned = category != nil && !Self.isGeneric(title: title, app: appName)
            && Self.memory[Self.memoryKey(bundle: bundle, title: title)] == category
            && Self.usableMemoryKey(Self.memoryKey(bundle: bundle, title: title))
            && !labelUncertain
        lastSnapshot = Snapshot(date: now, app: appName, bundle: bundle, title: url.map { "\(title) · \($0)" } ?? title,
                                text: text, others: otherTexts,
                                category: category, summary: summary, source: labelSource,
                                active: PresenceMonitor.idleSeconds < 90, seconds: Date().timeIntervalSince(now),
                                reason: labelReason, uncertain: labelUncertain)
        if PresenceMonitor.idleSeconds < 90 {
            taskContext.record(app: appName, title: title, category: category, summary: summary, text: text,
                               confirmed: learned, uncertain: labelUncertain, at: now)
        }
        let source: String? = labelSource.hasPrefix("your earlier answer") ? "you"
            : labelSource == "your Focus project rule" ? "rule"
            : labelSource.hasPrefix("kept") ? "held"
            : labelSource.contains("model") ? "model" : nil
        let browser = Self.browsers.contains(bundle)
        let privateMarker = (shot.title + "\n" + read.fullText).range(of: #"(?i)\b(incognito|private browsing)\b"#, options: .regularExpression) != nil
        let privacy: ScreenJournal.Privacy = browser ? (privateMarker ? .incognito : BrowserWindowPrivacy.decide(
            report: focusReportAtCapture, capturedTitle: shot.title, windowChangedAt: windowChangedAtCapture,
            capturedAt: capturedAt, nativeWindowMatches: Self.frontWindowID(pid: app.processIdentifier) == shot.windowID,
            isChrome: bundle == "com.google.Chrome")) : .notBrowser
        practiceObservations.send(.init(at: now, slug: LeetCodePracticeEvidence.slug(
            url: url, privacy: privacy, active: idle < 90 && category != "Admin")))
        ScreenJournalStore.shared.record(.init(at: now, end: now.addingTimeInterval(Self.interval),
            app: appName, bundle: bundle, windowID: "\(app.processIdentifier):\(shot.windowID)", title: title,
            url: privacy == .incognito ? nil : url, category: category, trackedCategory: trackedAtCapture, active: idle < 90,
            idleSeconds: idle, privacy: privacy, evidenceImageID: imageID, text: read.fullText), token: journalToken)
        record(ScreenSample(date: now, app: appName, bundleID: bundle, title: title,
                            summary: summary, category: category, active: PresenceMonitor.idleSeconds < 90,
                            learned: learned, source: source, reason: labelReason, uncertain: labelUncertain))
    }

    private func canRecordSample(generation: Int, bundle: String) -> Bool {
        generation == sampleGeneration && settings?.screenWatch == true && !PresenceMonitor.shared.isAway
            && PresenceMonitor.idleSeconds < 300 && !Self.privateApps.contains(bundle) && Self.userIgnored[bundle] == nil
    }

    private func record(_ s: ScreenSample) {
        samples.append(s)
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }

        let end = s.date.addingTimeInterval(Self.interval)
        let testMode = settings?.screenEverySwitch ?? false
        if var last = spans.last, last.bundleID == s.bundleID, last.title == s.title, last.category == s.category,
           (last.uncertain ?? false) == s.uncertain, last.testMode == testMode,
           s.date.timeIntervalSince(last.end) < Self.interval {
            last.end = end
            last.summary = s.summary
            last.active = (last.active ?? false) || s.active
            last.source = s.source ?? last.source
            last.reason = s.reason
            last.uncertain = s.uncertain
            spans[spans.count - 1] = last
        } else {
            if let last = spans.last, last.end > s.date { spans[spans.count - 1].end = s.date }
            spans.append(ScreenSpan(start: s.date, end: end, app: s.app, bundleID: s.bundleID,
                                    title: s.title, summary: s.summary, category: s.category, active: s.active,
                                    source: s.source, reason: s.reason, uncertain: s.uncertain, testMode: testMode))
        }
        unsavedSamples += 1
        if unsavedSamples >= 4 { save() }
        onSample?(s)
        Task { await updateNotes() }
    }

    /// After sleep, lid close, lock or display off the old evidence is stale.
    func resetEvidence() {
        practiceObservations.send(.init(at: Date(), slug: nil))
        sampleGeneration &+= 1
        samples.removeAll()
        taskContext.clear()
        cache.removeAll()
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
        if let known = Self.memory[Self.memoryKey(bundle: "ios", title: app)], candidates.contains(known) {
            let decision = ScreenClassificationPolicy.evaluate(category: known, app: app, title: "", text: "", source: .learned)
            if !decision.uncertain { return known }
        }
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
        return notesEntry(for: a)?.value
    }

    /// The notes overlapping this block most. Keying by exact start lost them
    /// whenever the start moved, and the writer then re-noted old blocks
    /// forever and never reached the live one (10/13: no notes after noon).
    private func notesEntry(for a: ScreenActivity) -> (key: Date, value: ActivityNotes)? {
        var best: (key: Date, value: ActivityNotes, overlap: TimeInterval)?
        for (k, n) in activityNotes {
            let s = n.start ?? k, e = n.end ?? k.addingTimeInterval(60)
            let o = min(e, a.end).timeIntervalSince(max(s, a.start))
            guard o > 0 || (s >= a.start && s < a.end) else { continue }
            if best == nil || o > best!.overlap { best = (k, n, max(o, 0)) }
        }
        return best.map { ($0.key, $0.value) }
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
        let liveDue = live.flatMap { b in
            !fresh(b).isEmpty && now.timeIntervalSince(notes(for: b)?.updatedAt ?? .distantPast) >= 90 ? b : nil
        }
        // Live block first, then the newest finished block with unread pages.
        let target = liveDue ?? blocks.reversed().first { $0.id != live?.id && !fresh($0).isEmpty }
        guard let b = target else { return }
        let pages = fresh(b)
        noting = true
        stage = "Writing notes for \(b.category ?? "this block")"
        defer { noting = false; if stage.hasPrefix("Writing notes") { stage = "" } }
        let previous = notes(for: b)
        if let (title, bullets) = await ScreenLabeler.studyNotes(
            category: b.category ?? "Unlabeled", windows: b.distinctTitles,
            previous: previous.map { ($0.title, $0.bullets) },
            pages: pages.map { ($0.window, $0.text) }
        ) {
            for (k, n) in activityNotes {
                let s = n.start ?? k, e = n.end ?? k
                if (s >= b.start && s < b.end) || (e > b.start && s < b.end) { activityNotes[k] = nil }
            }
            activityNotes[b.start] = ActivityNotes(title: title, bullets: bullets, updatedAt: now,
                                                   textThrough: pages.map(\.date).max() ?? now,
                                                   start: b.start, end: b.end)
        }
    }

    // MARK: - Capture + OCR

    private struct Shot: @unchecked Sendable {
        let image: CGImage
        let title: String
        let heightPoints: CGFloat
        let windowID: CGWindowID
    }

    /// Their tab strip and bookmarks bar OCR first and filled the 1500-char
    /// budget (godbolt read as "Ask Gemini / 3231 Study Guides / …" → Math).
    nonisolated private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser",
    ]
    nonisolated private static let browserChromePoints: CGFloat = 120

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

    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width > 200 && rect.height > 150
        }?[kCGWindowNumber as String] as? CGWindowID
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
        // 0xF0C5: the design gallery's virtual display (DesignGallery.swift).
        let displays = ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != 0xF0C5 }.map { CGDisplayBounds($0) }
        let center = { (r: CGRect) in CGPoint(x: r.midX, y: r.midY) }
        var others: [(String, Shot, String)] = []
        for d in displays where !d.contains(center(front.bounds)) {
            guard let top = windows.first(where: { d.contains(center($0.bounds)) }),
                  let app = NSRunningApplication(processIdentifier: top.pid),
                  let bundle = app.bundleIdentifier,
                  !privateApps.contains(bundle), !ignoredApps.contains(bundle), bundle != ownBundle else { continue }
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
        return Shot(image: image, title: window.title ?? fallbackTitle, heightPoints: window.frame.height, windowID: id)
    }

    nonisolated private static func recognizeText(_ image: CGImage, skipTop: CGFloat = 0) -> String {
        recognize(image, skipTop: skipTop).text
    }

    /// Chat apps title every window with the app's name; the conversation's
    /// own title sits in the top bar, so it's read from there instead.
    static let chatApps: Set<String> = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop"]

    /// Text plus the longest main-column line in the title bar (a chat's title).
    nonisolated private static func recognize(_ image: CGImage, skipTop: CGFloat = 0,
                                            includeSidebar: Bool = true) -> (text: String, fullText: String, header: String?) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Main column first, then a left sidebar: sorted by height alone, chat
        // apps interleaved "Projects / Artifacts / Routines" into every paragraph.
        let boxes = (request.results ?? []).filter { $0.boundingBox.maxY <= 1 - skipTop }
        let isSidebar = { (o: VNRecognizedTextObservation) in o.boundingBox.maxX < 0.24 }
        let ordered = boxes.filter { !isSidebar($0) }.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            + (includeSidebar ? boxes.filter(isSidebar).sorted { $0.boundingBox.minY > $1.boundingBox.minY } : [])
        let lines = ordered.compactMap { $0.topCandidates(1).first?.string }
        // Title bar only (ChatGPT's sits at 0.97): content scrolls up to ~0.94.
        let header = boxes.filter { !isSidebar($0) && $0.boundingBox.minY > 0.955 }
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.replacingOccurrences(of: #"\s+[VvY⌄]$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " v⌄›>•")) }
            // Text scrolled under the translucent bar reads as sentences; titles don't.
            .filter { (6...60).contains($0.count) && !$0.contains(". ") && !$0.hasSuffix(".") }
            .max { $0.count < $1.count }
        let fullLines = (request.results ?? []).compactMap { observation -> ScreenTextLayout.Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return .init(text: text, minX: box.minX, maxX: box.maxX, minY: box.minY, maxY: box.maxY)
        }
        let fullText = ScreenTextLayout.ordered(fullLines).joined(separator: "\n")
        return (String(lines.joined(separator: "\n").prefix(2500)), fullText, header)
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
            || ["new chat", "new conversation", "untitled", "untitled chat"].contains(t)
    }

    nonisolated static func memoryKey(bundle: String, title: String) -> String {
        bundle + "|" + title.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static let memoryDefaultsKey = "screenMemory"
    private static let keptMemoryDefaultsKey = "screenMemoryKeptTitles"

    static var memory: [String: String] {
        UserDefaults.standard.dictionary(forKey: memoryDefaultsKey) as? [String: String] ?? [:]
    }

    struct SuspiciousLabel: Identifiable {
        let key: String
        let title: String
        let category: String
        let reason: String
        var id: String { key }
    }

    private static var keptTitles: [String: String] {
        UserDefaults.standard.dictionary(forKey: keptMemoryDefaultsKey) as? [String: String] ?? [:]
    }

    private static func titleInMemoryKey(_ key: String) -> String? {
        guard let bar = key.firstIndex(of: "|") else { return nil }
        return String(key[key.index(after: bar)...])
    }

    static func usableMemoryKey(_ key: String) -> Bool {
        guard let title = titleInMemoryKey(key) else { return false }
        if LearnedTitlePolicy.reason(title) == nil { return true }
        guard let category = memory[key] else { return false }
        return keptTitles[key] == category
    }

    static var suspiciousLabels: [SuspiciousLabel] {
        memory.compactMap { key, category in
            let title = titleInMemoryKey(key) ?? key
            guard let reason = titleInMemoryKey(key) == nil ? "Has no app/window separator" : LearnedTitlePolicy.reason(title),
                  keptTitles[key] != category else { return nil }
            return SuspiciousLabel(key: key, title: title, category: category, reason: reason)
        }.sorted { $0.key < $1.key }
    }

    static func reviewLearnedLabel(_ entry: SuspiciousLabel, keep: Bool) -> Bool {
        var labels = memory
        guard labels[entry.key] == entry.category else { return false }
        var kept = keptTitles
        if keep {
            kept[entry.key] = entry.category
        } else {
            labels.removeValue(forKey: entry.key)
            kept.removeValue(forKey: entry.key)
            UserDefaults.standard.set(labels, forKey: memoryDefaultsKey)
        }
        UserDefaults.standard.set(kept, forKey: keptMemoryDefaultsKey)
        shared.objectWillChange.send()
        return true
    }

    // MARK: - Few-shot examples

    private lazy var titleEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var titleVectors: [String: [Double]] = [:]

    /// Up to 4 windows you've labeled whose titles mean something close to
    /// this one ("Plan MATH 244 midterm prep" for "MATH 244 problem set 6").
    private func examples(like title: String, among categories: [String]) -> [(title: String, category: String)] {
        let subject = LearnedTitlePolicy.subject(title)
        guard let emb = titleEmbedding, subject.count >= 4, let q = emb.vector(for: subject) else { return [] }
        var scored: [(sim: Double, title: String, category: String)] = []
        for (key, label) in Self.memory where categories.contains(label) {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let t = String(key[key.index(after: bar)...])
            guard t.count >= 4, t != title.lowercased(), LearnedTitlePolicy.reason(t) == nil else { continue }
            let ts = LearnedTitlePolicy.subject(t)
            guard ts.count >= 4, let v = titleVectors[ts] ?? emb.vector(for: ts) else { continue }
            titleVectors[ts] = v
            scored.append((Self.cosine(q, v), t, label))
        }
        let top = scored.filter { $0.sim >= 0.55 }.sorted { $0.sim > $1.sim }.prefix(4)
        if let best = top.first, best.sim >= 0.8, top.dropFirst().allSatisfy({ $0.sim < 0.8 || $0.category == best.category }) {
            nearMatch = best
        }
        return top.map { ($0.title, $0.category) }
    }

    /// Set by `examples(like:)`: a window you labeled that's nearly the same
    /// title (0.8+), whose label is used without asking the model.
    private var nearMatch: (sim: Double, title: String, category: String)?

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// The user's answer for these windows beats the model next time.
    static func learn(_ keys: Set<String>, as category: String) {
        let accepted = keys.filter { titleInMemoryKey($0).map { LearnedTitlePolicy.reason($0) == nil } ?? false }
        guard !accepted.isEmpty else { return }
        var m = memory
        for k in accepted { m[k] = category }
        if m.count > 800 {
            let protected = m.filter { titleInMemoryKey($0.key).map { LearnedTitlePolicy.reason($0) != nil } ?? true }
            let ordinary = m.filter { protected[$0.key] == nil }.sorted {
                if accepted.contains($0.key) != accepted.contains($1.key) { return accepted.contains($0.key) }
                return $0.key < $1.key
            }
            let retained = ordinary.prefix(max(0, 800 - protected.count)).map { ($0.key, $0.value) }
            m = protected.merging(Dictionary(uniqueKeysWithValues: retained)) { a, _ in a }
        }
        UserDefaults.standard.set(m, forKey: memoryDefaultsKey)
        shared.objectWillChange.send()
    }

    private func classify(app: String, bundle: String, title: String, text: String, url: String? = nil) async -> (String?, String) {
        let generation = sampleGeneration
        let fallbackSummary = title.isEmpty ? app : "\(app): \(title)"
        let candidates = candidateCategories()
        let generic = Self.isGeneric(title: title, app: app)
        labelReason = ""
        labelUncertain = false
        if candidates.contains("Admin"), ScreenClassificationPolicy.isFocusProjectWork(title: title, text: text) {
            labelSource = "your Focus project rule"
            labelReason = "Your rule: work on the Focus project is Admin"
            return ("Admin", fallbackSummary)
        }
        if candidates.contains(FocusCategories.leetCode), ScreenClassificationPolicy.isLeetCodePractice(title: title, url: url) {
            labelSource = "LeetCode practice site"
            labelReason = "LeetCode or NeetCode interview practice"
            return (FocusCategories.leetCode, fallbackSummary)
        }
        if candidates.contains("SWE"), ScreenClassificationPolicy.isCodingPractice(title: title, url: url) {
            labelSource = "coding practice site"
            labelReason = "A coding practice site"
            return ("SWE", fallbackSummary)
        }
        if candidates.contains("Journaling"), ScreenClassificationPolicy.isJournalApp(app: app, bundle: bundle) {
            labelSource = "journal app"
            labelReason = "A journal app"
            return ("Journaling", fallbackSummary)
        }
        if candidates.contains("AI"), ScreenClassificationPolicy.supportsMLStudy(title: title, text: text) {
            labelSource = "visible ML study rule"
            labelReason = "Visible ML/deep-learning study or research material"
            return ("AI", fallbackSummary)
        }
        if !generic, Self.usableMemoryKey(Self.memoryKey(bundle: bundle, title: title)),
           let known = Self.memory[Self.memoryKey(bundle: bundle, title: title)], candidates.contains(known) {
            let decision = ScreenClassificationPolicy.evaluate(category: known, app: app, title: title, text: text, source: .learned)
            if decision.category == known {
                labelSource = "your earlier answer for this window"
                labelReason = decision.reason.isEmpty ? "You labeled this conversation or window \(known)" : decision.reason
                return (known, cache[cacheKey(bundle, title, text)]?.summary ?? fallbackSummary)
            }
        }
        let key = cacheKey(bundle, title, text)
        if let hit = cache[key], !hit.uncertain {
            let decision = ScreenClassificationPolicy.evaluate(category: hit.category, app: app, title: title, text: text)
            if !decision.uncertain, decision.category == hit.category {
                labelSource = "model (same page as before)"
                labelReason = hit.reason
                return (hit.category, hit.summary)
            }
        }
        guard #available(macOS 26.0, *), Self.modelAvailable, !text.isEmpty || !title.isEmpty else {
            labelSource = "nothing to go on"
            labelReason = "No available local model or visible text for this task"
            labelUncertain = true
            return (nil, fallbackSummary)
        }
        labelSource = "on-device model"
        let window = Self.memoryKey(bundle: bundle, title: title)
        nearMatch = nil
        let shots = generic || LearnedTitlePolicy.reason(title) != nil ? [] : examples(like: title, among: candidates)
        if let near = nearMatch {
            let decision = ScreenClassificationPolicy.evaluate(category: near.category, app: app, title: title, text: text, source: .learned)
            if !decision.uncertain {
                labelSource = "your earlier answer for a similar window (\"\(near.title)\", \(Int(near.sim * 100))% alike)"
                labelReason = decision.reason.isEmpty ? "Similar to your \(near.category) label for \(near.title)" : decision.reason
                return (near.category, cache[key]?.summary ?? fallbackSummary)
            }
        }
        if !shots.isEmpty { labelSource = "on-device model, with \(shots.count) of your labels as examples" }
        guard let classification = await ScreenLabeler.classifyDetailed(app: app, title: title, text: text, categories: candidates,
                                                        current: runningCategory(), examples: shots,
                                                        taskContext: taskContext.promptContext(), url: url) else {
            // The model threw (often its rate limit for background apps): keep
            // this window's last label instead of leaving a hole in the log.
            let held = generic ? samples.last { $0.bundleID == bundle }?.category : windowLabel[window]?.category
            labelSource = "kept \(held ?? "nothing"): the model failed (\(ScreenLabeler.lastError ?? "unknown"))"
            let decision = ScreenClassificationPolicy.evaluate(category: held, app: app, title: title, text: text, source: .held)
            labelReason = "Local model unavailable; previous label is unverified for this screen"
            labelUncertain = true
            return (decision.category, fallbackSummary)
        }
        guard generation == sampleGeneration else {
            labelReason = "This observation expired while the local model was working"
            labelUncertain = true
            return (nil, fallbackSummary)
        }
        var result = (classification.category, classification.summary)
        labelReason = classification.reason
        labelUncertain = classification.uncertain
        if let c = result.0, !generic, !labelUncertain {
            if let held = windowLabel[window], held.category != c, candidates.contains(held.category),
               !ScreenClassificationPolicy.evaluate(category: held.category, app: app, title: title, text: text, source: .held).uncertain {
                if held.against + 1 >= (settings?.screenEverySwitch == true ? 2 : 3) {
                    windowLabel[window] = (c, 0)
                } else {
                    windowLabel[window] = (held.category, held.against + 1)
                    labelSource = "kept \(held.category): model said \(c), \(held.against + 1) of \(settings?.screenEverySwitch == true ? 2 : 3) disagreements to switch"
                    result.0 = held.category
                    labelReason = "Waiting for consistent evidence of \(c). \(classification.reason)"
                    labelUncertain = true
                }
            } else {
                windowLabel[window] = (c, 0)
            }
            if windowLabel.count > 300 { windowLabel.removeAll() }
        }
        if cache.count > 400 { cache.removeAll() }
        if !labelUncertain {
            cache[key] = CachedLabel(category: result.0, summary: result.1, reason: labelReason, uncertain: false)
        }
        return result
    }

    private func cacheKey(_ bundle: String, _ title: String, _ text: String) -> String {
        "\(runningCategory() ?? "")|\(bundle)|\(title)|\(text.prefix(300).hashValue)"
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
    var topTitle: String {
        let t = distinctTitles.first ?? "Unknown"
        guard let s = spans.first(where: { ($0.title.isEmpty ? $0.app : "\($0.app): \($0.title)") == t }),
              ScreenWatcher.isGeneric(title: s.title, app: s.app) else { return t }
        return distinctSummaries.first { !$0.hasPrefix("\(s.app):") && $0 != s.app } ?? t
    }
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
    var source: String? = nil
    var reason: String? = nil
    var uncertain = false
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
        let reset: @Sendable (Notification) -> Void = { [weak self] _ in
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
        /// Every snapshot's label came from your own answers.
        let trusted: Bool
        let projectAdmin: Bool
    }

    /// The model labeled the window, or you did earlier: your own label needs
    /// less proof, so a window you've answered for before is suggested in 45s.
    private static let learnedRunSeconds: TimeInterval = 45

    /// Trailing stretch where ≥ 80% of active samples say the same category.
    /// Two misses in a row, a 60s hole (sleep, away, paused) or the moment you
    /// picked the current category ends it: what was on screen before your
    /// own choice isn't evidence against it.
    private func trailingRun(notBefore floor: Date?, running: String?) -> Run? {
        let samples = watcher.samples.filter { $0.bundleID != ScreenWatcher.ownBundle && $0.summary != "Private" }
        guard let last = samples.last, last.active, !last.uncertain, let c = last.category else { return nil }
        var start = last.date, hits = 0, total = 0, missStreak = 0
        var keyCounts: [String: Int] = [:]
        var allLearned = true
        var allProjectAdmin = c == "Admin"
        var newer = last.date
        for s in samples.reversed() {
            if newer.timeIntervalSince(s.date) > 60 { break }
            if let floor, s.date < floor { break }
            newer = s.date
            guard s.active else { continue }
            total += 1
            if s.category == c && !s.uncertain {
                hits += 1; missStreak = 0; start = s.date
                if !ScreenWatcher.isGeneric(title: s.title, app: s.app) { keyCounts[s.memoryKey, default: 0] += 1 }
                allLearned = allLearned && s.learned
                allProjectAdmin = allProjectAdmin && s.source == "rule"
            } else {
                missStreak += 1
                if missStreak >= 2 { total -= 2; break }
            }
        }
        // A learned life label during focus is a side trip until it lasts
        // (10/15: three Admin cards for glances at agent chats mid-Math, all
        // kept; learned focus→life cards had never been taken).
        let leavesFocus = running.map { $0 != "Break" && !FocusCategories.isLife($0) } ?? false
        let followsYourRule = (allLearned || allProjectAdmin) && !(leavesFocus && FocusCategories.isLife(c))
        let needed = settings.screenEverySwitch ? 25 : followsYourRule ? Self.learnedRunSeconds : Double(settings.screenSuggestMinutes) * 60
        guard hits >= (settings.screenEverySwitch ? 2 : followsYourRule ? 3 : 4), Double(hits) / Double(max(total, 1)) >= 0.8,
              last.date.timeIntervalSince(start) >= needed else { return nil }
        // Your answer teaches the windows the run was made of, not one stray
        // snapshot of another window the model happened to call the same
        // (10/13: accepting Math taught this Claude chat "Math").
        let keys = Set(keyCounts.filter { $0.value >= 2 && Double($0.value) >= Double(hits) * 0.25 }.keys)
        return Run(category: c, start: start, keys: keys, summary: last.summary,
                   trusted: allLearned, projectAdmin: allProjectAdmin)
    }

    /// Plain-language reason no card fired, from the recent snapshots.
    private func evidenceStatus(running: String?) -> String {
        let floor = timer.isActive ? timer.sessionStartTime : nil
        let recent = watcher.samples.filter { s in
            Date().timeIntervalSince(s.date) < 600 && s.date >= (floor ?? .distantPast)
                && s.bundleID != ScreenWatcher.ownBundle && s.summary != "Private"
        }
        guard let last = recent.last else { return "No snapshots since you picked \(running ?? "this")" }
        guard !last.uncertain else { return last.reason ?? "Not enough evidence to suggest a switch" }
        guard last.active else { return "You've been idle, so snapshots don't count" }
        guard let c = last.category else { return "Last snapshot had no label" }
        if c == running { return "Screen agrees with \(c)" }
        var start = last.date
        for s in recent.reversed() where s.active {
            if s.category == c { start = s.date } else { break }
        }
        let have = Int(last.date.timeIntervalSince(start))
        let sideTrip = running.map { $0 != "Break" && !FocusCategories.isLife($0) } ?? false && FocusCategories.isLife(c)
        let need = settings.screenEverySwitch ? 25 : last.learned && !sideTrip ? Int(Self.learnedRunSeconds) : settings.screenSuggestMinutes * 60
        return "Screen says \(c) for \(have)s; a card needs \(need)s of mostly \(c)"
    }

    private func consider() {
        let say = { [watcher] (s: String) in watcher.coachStatus = s }
        guard settings.screenSuggest else { return say("Suggestions are off") }
        guard days.isDayStarted else { return say("Day not started") }
        guard !panel.isBusy, !(AwayCoach.shared?.isBusy ?? false), !LeetCodeSolveDraftStore.isShowing else { return say("A card is already showing") }
        // In class you're in Class, whatever the screen shows, until the
        // calendar class is over (10/14: Class ran 1.5 h past the exam).
        if timer.isActive, !timer.isOnBreak, timer.currentLabel == "Class" {
            if let start = timer.sessionStartTime, let ended = ClassCalendar.shared.endedClass(since: start),
               !classExitAsked.contains(Self.classKey(ended)) {
                say("Class ended on your calendar: \(ended.title ?? "")")
                suggestClassExit(ended)
                return
            }
            return say("In Class: no suggestions")
        }
        // "Still SWE" on the class card means you're not in it (10/13: kept
        // SWE on all four), so the screen gets its say again.
        if let lecture = ClassCalendar.shared.currentClass(), !classDeclined.contains(Self.classKey(lecture)) {
            say("In class on your calendar: \(lecture.title ?? "")")
            suggestClass(lecture)
            return
        }
        let running: String? = timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : nil
        guard let run = trailingRun(notBefore: timer.isActive ? timer.sessionStartTime : nil, running: running) else {
            return say(evidenceStatus(running: running))
        }
        if timer.isActive && !timer.isRunning { return say("Timer paused") }
        guard running != run.category else { return say("Screen agrees with \(run.category)") }
        if let until = snoozed[run.category], until > Date() {
            return say("\(run.category) snoozed until \(until.formatted(date: .omitted, time: .shortened)) (you said Still)")
        }
        if run.projectAdmin {
            say("Switched to Admin: your Focus project rule")
            if let from = running { return autoSwitch(from: from, to: run) }
            timer.switchTo("Admin", at: run.start)
            return
        }
        // Browsing in bed with Sleep running isn't a switch (10/14: four
        // Reading/Admin cards after midnight, none taken). Work still asks.
        if let running, ScreenWatcher.offScreenCategories.contains(running), FocusCategories.isLife(run.category) {
            return say("During \(running), only focus work gets a card")
        }
        // Focus → focus on windows you've labeled yourself: just switch, with
        // Undo. Anything involving a life category stays a question.
        if settings.screenAutoSwitch, run.trusted, let from = running, from != "Break",
           !FocusCategories.isLife(from), !FocusCategories.isLife(run.category) {
            say("Switched to \(run.category): windows you've labeled \(run.category) before")
            return autoSwitch(from: from, to: run)
        }
        say("Showing a card: \(run.category) since \(run.start.formatted(date: .omitted, time: .shortened))")

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
                // Picking HW on a "Looks like Leisure" card over a YouTube clip
                // means "I'm starting HW", not "that clip was HW" (10/14).
                if !FocusCategories.isLife(label), label == run.category || !FocusCategories.isLife(run.category) {
                    ScreenWatcher.learn(run.keys, as: label)
                }
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
            // Except chat windows: "Still Math" while asking Claude about
            // something else is a side trip, and taught that chat "Math" (10/13).
            if let running, running != "Break", !FocusCategories.isLife(running), !FocusCategories.isLife(run.category) {
                let keys = run.keys.filter { k in !ScreenWatcher.chatApps.contains { k.hasPrefix($0 + "|") } }
                ScreenWatcher.learn(keys, as: running)
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

    private func autoSwitch(from: String, to run: Run) {
        timer.switchTo(run.category, at: run.start)
        let m = AwayPromptModel(
            icon: "arrow.triangle.swap",
            title: "Switched to \(run.category)",
            subtitle: "since \(run.start.formatted(date: .omitted, time: .shortened)) · \(run.projectAdmin ? "your Focus project rule" : "windows you've labeled \(run.category)")",
            question: run.summary,
            keep: "Undo, still \(from)",
            options: [], tags: settings.tags
        )
        let logID = PromptLog.screenPrompt(model: m, running: from, suggested: run.category, since: run.start,
                                           samples: watcher.samples, pages: watcher.pages(since: run.start),
                                           reason: "auto-switch")
        m.onKeep = { [weak self] in
            guard let self else { return }
            PromptLog.answer(logID, "undid, kept \(from)")
            self.timer.relabelRunning(from)
            ScreenWatcher.learn(run.keys, as: from)
            Self.bump(Self.declinedKey)
            self.snoozed[run.category] = Date().addingTimeInterval(20 * 60)
            self.panel.dismiss()
        }
        m.onPick = { [weak self] label in
            guard let self else { return }
            PromptLog.answer(logID, "changed to \(label ?? "Break")")
            if let label { self.timer.relabelRunning(label) } else { self.timer.startManualBreak(minutes: 0, at: run.start) }
            self.panel.dismiss()
        }
        Self.bump(Self.acceptedKey)
        panel.show(m)
        let close = m.onClose
        m.onClose = {
            PromptLog.answer(logID, "kept the switch")
            close?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.panel.isBusy else { return }
            m.onClose?()
        }
    }

    /// Persisted: a relaunch mid-class asked about the same lecture twice (10/13).
    private var classPrompted = loadClassKeys("screenClassPrompted") {
        didSet { Self.saveClassKeys(classPrompted, "screenClassPrompted") }
    }
    private var classDeclined = loadClassKeys("screenClassDeclined") {
        didSet { Self.saveClassKeys(classDeclined, "screenClassDeclined") }
    }
    private var classExitAsked = loadClassKeys("screenClassExitAsked") {
        didSet { Self.saveClassKeys(classExitAsked, "screenClassExitAsked") }
    }

    private static func loadClassKeys(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func saveClassKeys(_ keys: Set<String>, _ key: String) {
        let dayAgo = Date().timeIntervalSince1970 - 86400
        let recent = keys.filter { k in (k.split(separator: "@").last.flatMap { Double($0) } ?? 0) > dayAgo }
        UserDefaults.standard.set(Array(recent), forKey: key)
    }

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

    /// Once per calendar class, when Class is still running after it ended:
    /// what since? Picking backdates the switch to the class end; closing or
    /// "Still in Class" changes nothing.
    private func suggestClassExit(_ lecture: EKEvent) {
        let key = Self.classKey(lecture)
        classExitAsked.insert(key)
        let end: Date = lecture.endDate
        let clock = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let classStart = timer.sessionStartTime ?? end
        let before = timer.sessionStore?.sessions
            .filter { !$0.type.isBreak && $0.label != "Class" && $0.startTime < classStart }
            .max { $0.startTime < $1.startTime }?.label
        var options: [String?] = []
        for c in [before, "Leisure", "Meals"] {
            if let c, settings.tags.contains(c), !options.contains(c) { options.append(c) }
        }
        options.append(nil)
        let m = AwayPromptModel(
            icon: "graduationcap",
            title: "Class ended at \(clock(end))",
            subtitle: "\(lecture.title ?? "Class") · from your calendar",
            question: "What have you been doing since?",
            keep: "Still in Class",
            options: options, tags: settings.tags
        )
        let logID = PromptLog.screenPrompt(model: m, running: "Class", suggested: before ?? "Leisure", since: end,
                                           samples: [], pages: [], reason: "calendar class ended: \(lecture.title ?? "")")
        m.onPick = { [weak self] label in
            guard let self else { return }
            PromptLog.answer(logID, "switched to \(label ?? "Break")")
            if let label { self.timer.switchTo(label, at: end) } else { self.timer.startManualBreak(minutes: 0, at: end) }
            self.panel.dismiss()
        }
        m.endTitle = "End Class at \(clock(end))"
        m.onEnd = { [weak self] in
            guard let self else { return }
            PromptLog.answer(logID, "ended Class")
            if self.timer.currentLabel == "Class" { self.timer.stop(at: end) }
            self.panel.dismiss()
        }
        m.onKeep = { [weak self] in
            PromptLog.answer(logID, "kept Class")
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
        snoozed[category] = Date().addingTimeInterval(settings.screenEverySwitch ? 120 : 20 * 60)
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
        var reason: String? = nil
        var uncertain: Bool? = nil
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
        var testMode: Bool? = nil
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
                Snapshot(at: $0.date, app: $0.app, title: $0.title, summary: $0.summary, category: $0.category,
                         active: $0.active, reason: $0.reason, uncertain: $0.uncertain)
            },
            pages: pages.suffix(12).map { Page(at: $0.date, window: $0.window, text: String($0.text.prefix(1500))) },
            testMode: UserDefaults.standard.bool(forKey: "screenEverySwitch")
        ))
        return id
    }

    /// Cards since `date`, newest first, each with its answer (nil = ignored).
    static func cards(since date: Date) -> [(at: Date, card: String, subtitle: String, reason: String, answer: String?)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var cards: [UUID: Line] = [:], answers: [UUID: String] = [:]
        for row in raw.split(separator: "\n") {
            guard let l = try? dec.decode(Line.self, from: Data(row.utf8)), l.at >= date else { continue }
            if let a = l.answer { answers[l.id] = a } else if l.card != nil { cards[l.id] = l }
        }
        return cards.values.sorted { $0.at > $1.at }.map {
            ($0.at, $0.card ?? "", $0.subtitle ?? "", $0.reason ?? "", answers[$0.id])
        }
    }

    static func scorecardCards(since date: Date) -> [TrustScorecard.Card] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var shown: [UUID: Line] = [:], answers: [UUID: String] = [:]
        for row in raw.split(separator: "\n") {
            guard let line = try? decoder.decode(Line.self, from: Data(row.utf8)) else { continue }
            if let answer = line.answer { answers[line.id] = answer }
            else if line.at >= date, ["screen", "auto-switch"].contains(line.reason ?? "") { shown[line.id] = line }
        }
        return shown.values.map {
            .init(shown: $0.at, since: $0.since, answer: answers[$0.id], automatic: $0.reason == "auto-switch",
                  mode: $0.testMode.map { $0 ? .test : .normal } ?? .unknown)
        }
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
