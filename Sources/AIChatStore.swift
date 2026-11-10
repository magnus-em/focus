import AppKit
import ApplicationServices
import Combine
import FocusCore

/// Your own messages to AI tools, word for word, in `Focus/ai-chats/YYYY-MM.jsonl`
/// (this Mac only). Three sources: the ChatGPT and Claude desktop windows,
/// read through Accessibility every 4 s while one is in front (their pages
/// mark your messages with a "user-message" class); the Claude Code and
/// Codex transcripts on disk, scanned every 10 min; and data exports you
/// import. Temporary/incognito chats are skipped.
@MainActor
final class AIChatStore: ObservableObject {
    static let shared = AIChatStore()
    static let enabledKey = "aiChatCapture"
    static let windowApps: [String: String] = ["com.openai.chat": "ChatGPT", "com.anthropic.claudefordesktop": "Claude"]

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    @Published private(set) var status = ""
    @Published private(set) var weekCount = 0
    @Published private(set) var trusted = AXIsProcessTrusted()

    private var settings: AppSettings?
    private var timer: Timer?
    private var transcriptTimer: Timer?
    private var reading = false
    private var previous: [String: AIChats.WindowRead] = [:]
    private var seenIDs: Set<String> = []
    private var seenText: Set<String> = []
    private nonisolated static let axQueue = DispatchQueue(label: "focus.aichats.ax", qos: .utility)
    private nonisolated static let ioQueue = DispatchQueue(label: "focus.aichats.io", qos: .utility)

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/ai-chats", isDirectory: true)
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start(settings: AppSettings) {
        self.settings = settings
        guard timer == nil else { return }
        Self.ioQueue.async {
            let all = Self.load(from: .distantPast, to: .distantFuture, dedupe: false)
            let ids = Set(all.map(\.id)), text = Set(all.map(\.textKey))
            Task { @MainActor in
                self.seenIDs.formUnion(ids)
                self.seenText.formUnion(text)
                self.refreshCount()
                self.scanTranscripts()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        transcriptTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanTranscripts() }
        }
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    private func tick() {
        trusted = AXIsProcessTrusted()
        guard enabled, settings?.screenWatch == true, trusted, !reading, !PresenceMonitor.shared.isAway,
              PresenceMonitor.idleSeconds < 120,
              let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              let tool = Self.windowApps[bundle], ScreenWatcher.userIgnored[bundle] == nil else { return }
        reading = true
        let pid = app.processIdentifier
        let now = Date()
        Self.axQueue.async {
            let read = Self.readWindow(pid: pid, tool: tool, at: now)
            Task { @MainActor in
                self.reading = false
                guard let read else { return }
                let new = AIChats.newMessages(previous: self.previous[tool], current: read, seenIDs: self.seenIDs,
                                              seenText: self.seenText)
                self.previous[tool] = read
                self.add(new)
                self.status = "Last read \(tool) at \(now.formatted(date: .omitted, time: .shortened))"
            }
        }
    }

    private func add(_ messages: [AIChats.Message]) {
        let fresh = messages.filter { !seenIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for m in fresh { seenIDs.insert(m.id); seenText.insert(m.textKey) }
        Self.ioQueue.async { Self.append(fresh) }
        refreshCount()
    }

    private func refreshCount() {
        let from = Date().addingTimeInterval(-7 * 86400)
        Self.ioQueue.async {
            let n = Self.load(from: from, to: Date()).count
            Task { @MainActor in self.weekCount = n }
        }
    }

    // MARK: - Accessibility read

    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()

    nonisolated static func readWindow(pid: pid_t, tool: String, at: Date) -> AIChats.WindowRead? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        if !enabledPIDs.contains(pid) {
            // Chromium-based apps only build their page tree for assistive tech that asks.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(pid)
        }
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        guard let w = attr(app, "AXFocusedWindow") else { return nil }
        var title: String?
        var messages: [String] = []
        var nodes = 0
        var temporary = false
        func text(_ e: AXUIElement, _ depth: Int) -> [String] {
            nodes += 1
            guard depth < 40, nodes < 8000 else { return [] }
            var out: [String] = []
            if (attr(e, "AXRole") as? String) == "AXStaticText", let v = attr(e, "AXValue") as? String, !v.isEmpty { out.append(v) }
            for k in attr(e, "AXChildren") as? [AXUIElement] ?? [] { out += text(k, depth + 1) }
            return out
        }
        func walk(_ e: AXUIElement, _ depth: Int) {
            nodes += 1
            guard depth < 90, nodes < 8000 else { return }
            let role = attr(e, "AXRole") as? String
            let sub = attr(e, "AXSubrole") as? String
            if sub == "AXLandmarkNavigation" || sub == "AXLandmarkComplementary" { return }
            if role == "AXWebArea", title == nil { title = attr(e, "AXTitle") as? String }
            if role == "AXStaticText" || role == "AXHeading",
               let v = (attr(e, "AXValue") as? String)?.lowercased(),
               v == "temporary chat" || v.hasPrefix("you're incognito") || v == "incognito chat" {
                temporary = true
            }
            if let classes = attr(e, "AXDOMClassList") as? [String], classes.contains(where: { $0.contains("user-message") }) {
                let t = text(e, 0).joined(separator: " ")
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { messages.append(t) }
                return
            }
            for k in attr(e, "AXChildren") as? [AXUIElement] ?? [] { walk(k, depth + 1) }
        }
        walk(w as! AXUIElement, 0)
        guard !temporary else { return nil }
        let clean = (title ?? "").replacingOccurrences(of: #"\s*[-–—|]\s*(Claude|ChatGPT)$"#, with: "", options: .regularExpression)
        return AIChats.WindowRead(tool: tool, title: clean, messages: messages, at: at)
    }

    // MARK: - Transcripts

    private struct ScanState: Codable {
        var offset: UInt64
        var cwd: String?
    }

    func scanTranscripts() {
        guard enabled else { return }
        Self.ioQueue.async {
            let found = Self.scan()
            Task { @MainActor in self.add(found) }
        }
    }

    private nonisolated static var stateURL: URL { directory.appendingPathComponent("transcripts.json") }

    private nonisolated static func scan() -> [AIChats.Message] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var state = (try? JSONDecoder().decode([String: ScanState].self, from: Data(contentsOf: stateURL))) ?? [:]
        var out: [AIChats.Message] = []
        var files: [(URL, Bool)] = []
        let claude = home.appendingPathComponent(".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: claude, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
                files.append((f, false))
            }
        }
        if let e = fm.enumerator(at: home.appendingPathComponent(".codex/sessions"), includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension == "jsonl" { files.append((f, true)) }
        }
        let userMark = Data("\"user\"".utf8)
        for (f, codex) in files {
            guard let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.uint64Value else { continue }
            var s = state[f.path] ?? ScanState(offset: 0)
            guard size > s.offset, let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: s.offset)
            guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { continue }
            let body = data[data.startIndex...lastNL]
            for line in body.split(separator: 0x0A) {
                let d = Data(line)
                if codex, s.cwd == nil, let cwd = AIChats.codexCwd(d) { s.cwd = cwd; continue }
                guard d.range(of: userMark) != nil else { continue }
                if let m = codex ? AIChats.codexPrompt(d, cwd: s.cwd) : AIChats.claudeCodePrompt(d) { out.append(m) }
            }
            s.offset += UInt64(body.count)
            state[f.path] = s
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
        return out
    }

    // MARK: - Exports

    /// A ChatGPT or Claude export: the .zip, its folder, or conversations.json.
    func importExport(_ url: URL) async -> String {
        let result: (Int, String?) = await withCheckedContinuation { cont in
            Self.ioQueue.async {
                var file = url
                var tmp: URL?
                if url.pathExtension.lowercased() == "zip" {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    tmp = dir
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-x", "-k", url.path, dir.path]
                    try? p.run(); p.waitUntilExit()
                    file = dir
                }
                defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                    let e = FileManager.default.enumerator(at: file, includingPropertiesForKeys: nil)
                    file = (e?.allObjects as? [URL] ?? []).first { $0.lastPathComponent == "conversations.json" } ?? file
                }
                guard let data = try? Data(contentsOf: file) else { cont.resume(returning: (0, "Couldn't read \(url.lastPathComponent)")); return }
                let msgs = AIChats.exportMessages(data)
                cont.resume(returning: msgs.isEmpty ? (0, "No conversations found in \(url.lastPathComponent)") : (msgs.count, nil))
                Task { @MainActor in self.add(msgs) }
            }
        }
        if let err = result.1 { return err }
        return "Imported \(result.0) of your messages"
    }

    // MARK: - Files

    private nonisolated static func month(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private nonisolated static func append(_ messages: [AIChats.Message]) {
        let enc = JSONEncoder()
        var byMonth: [String: Data] = [:]
        for m in messages {
            guard let d = try? enc.encode(m) else { continue }
            byMonth[month(m.at), default: Data()].append(d + Data("\n".utf8))
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (k, data) in byMonth {
            let url = directory.appendingPathComponent("\(k).jsonl")
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    nonisolated static func load(from: Date, to: Date, dedupe: Bool = true) -> [AIChats.Message] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}\.jsonl$"#, options: .regularExpression) != nil }
        let lo = from == .distantPast ? "" : month(from), hi = to == .distantFuture ? "9999" : month(to)
        let dec = JSONDecoder()
        var out: [AIChats.Message] = []
        for f in files where String(f.lastPathComponent.prefix(7)) >= lo && String(f.lastPathComponent.prefix(7)) <= hi {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard var m = try? dec.decode(AIChats.Message.self, from: Data(line.utf8)), m.at >= from, m.at < to else { continue }
                // Rows saved before a filter improved are cleaned the same way on read.
                if m.tool == "Codex" { guard let t = AIChats.codexText(m.text) else { continue }; m.text = t }
                out.append(m)
            }
        }
        return dedupe ? AIChats.deduplicated(out) : out.sorted { $0.at < $1.at }
    }
}
