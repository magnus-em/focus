import Foundation
import FocusCore

/// App side of `YouTubeFeed`: remembers every verdict by video id
/// (`Focus/youtube/verdicts.json`, newest 6000, with the title so the rules can be tuned on real feeds)
/// and the user's channel rules (`Focus/youtube/channels.json`). Unknown videos go to Grok 40 at a time
/// when Cloud AI is on (inside the shared daily cap), else to the on-device model one at a time.
/// `Focus/youtube/page.json` holds the extension's latest page report and the last model error.
/// In hide-by-hand mode nothing is judged, and `Focus/youtube/feed-log.jsonl` records what was on screen,
/// opened and hidden (`YouTubeFeed.logEntry`).
actor YouTubeFeedFilter {
    static let shared = YouTubeFeedFilter()

    private struct Entry: Codable {
        var verdict: YouTubeFeed.Verdict
        var channel: String
        var title: String?
        var v: Int?
        var at: Date
    }

    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/youtube", isDirectory: true)
    private var verdicts: [String: Entry] = [:]
    private var rules: [String: Bool] = [:]
    private var loaded = false
    private var dirty = false
    private var working: Set<String> = []
    private var pending: [YouTubeFeed.Video] = []
    private var draining = false
    private var lastModelError: String?
    private var modelFailures = 0
    private var cloudDownUntil = Date.distantPast
    private var localDownUntil = Date.distantPast
    private var localMisses = 0
    private var localWarm = false
    private var seenToday: Set<String> = []
    private var seenDay = ""

    private var verdictsURL: URL { dir.appendingPathComponent("verdicts.json") }
    private var rulesURL: URL { dir.appendingPathComponent("channels.json") }
    private var logURL: URL { dir.appendingPathComponent("feed-log.jsonl") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        if let d = try? Data(contentsOf: verdictsURL), let v = try? decoder.decode([String: Entry].self, from: d) { verdicts = v }
        if let d = try? Data(contentsOf: rulesURL), let r = try? decoder.decode([String: Bool].self, from: d) { rules = r }
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        if verdicts.count > 6000 {
            for (id, _) in verdicts.sorted(by: { $0.value.at < $1.value.at }).prefix(verdicts.count - 6000) { verdicts[id] = nil }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(verdicts) { try? d.write(to: verdictsURL, options: .atomic) }
        if let d = try? JSONEncoder().encode(rules) { try? d.write(to: rulesURL, options: .atomic) }
    }

    func setChannel(_ channel: String, allow: Bool?) {
        load()
        let key = YouTubeFeed.channelKey(channel)
        guard !key.isEmpty else { return }
        rules[key] = allow
        dirty = true
        save()
    }

    /// The user's call on one video beats their channel rules and everything else; nil asks again.
    func setVideo(_ video: YouTubeFeed.Video, keep: Bool?) {
        load()
        working.remove(video.id)
        pending.removeAll { $0.id == video.id }
        verdicts[video.id] = keep.map {
            Entry(verdict: .init(keep: $0, source: .you), channel: video.channel, title: video.title, v: YouTubeFeed.version, at: Date())
        }
        dirty = true
        save()
    }

    func note(page: Data) {
        guard var out = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any] else { return }
        out["at"] = ISO8601DateFormatter().string(from: Date())
        out["modelQueue"] = pending.count
        out["modelFailures"] = modelFailures
        out["cloud"] = cloudUsable
        if let lastModelError { out["lastModelError"] = lastModelError }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("page.json"), options: .atomic)
        }
    }

    /// Answers at once from rules and the cache; videos it doesn't know yet go to the model in the
    /// background and are missing from the reply, so the extension asks again. The model can take
    /// ~40 s to wake up (11/7), longer than the extension waits.
    func classify(_ videos: [YouTubeFeed.Video], byHand: Bool = false) -> [String: YouTubeFeed.Verdict] {
        load()
        var out: [String: YouTubeFeed.Verdict] = [:]
        if byHand {
            for v in videos.prefix(60) {
                if let mine = verdicts[v.id], mine.verdict.source == .you { out[v.id] = mine.verdict }
                else { out[v.id] = YouTubeFeed.byHand(v, rules: rules) }
            }
            return out
        }
        for v in videos.prefix(60) where out[v.id] == nil {
            if let mine = verdicts[v.id], mine.verdict.source == .you {
                out[v.id] = mine.verdict
            } else if let quick = YouTubeFeed.quick(v, rules: rules) {
                out[v.id] = quick
            } else if let cached = verdicts[v.id], fresh(cached) {
                out[v.id] = cached.verdict
            } else if !working.contains(v.id), pending.count < 300 {
                working.insert(v.id)
                pending.append(v)
            }
        }
        if !pending.isEmpty, !draining {
            draining = true
            Task { await drain() }
        }
        return out
    }

    /// Appends the extension's events to the feed log; a video counts as seen once a day.
    func log(_ body: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return }
        let now = Date()
        let day = String(YouTubeFeed.localTime(now).prefix(10))
        if day != seenDay { loadSeen(day) }
        var lines = Data()
        for e in events.prefix(500) {
            guard let entry = YouTubeFeed.logEntry(e, at: now) else { continue }
            if entry["event"] as? String == "seen", let id = entry["id"] as? String, !seenToday.insert(id).inserted { continue }
            guard let d = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
            lines.append(d)
            lines.append(0x0A)
        }
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: lines)
    }

    private func loadSeen(_ day: String) {
        seenDay = day
        seenToday = []
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where line.contains("\"event\":\"seen\"") && line.contains("\"at\":\"\(day)") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = o["id"] as? String {
                seenToday.insert(id)
            }
        }
    }

    /// On-device verdicts are asked again once the cloud is back: it's right far more often.
    private func fresh(_ e: Entry) -> Bool {
        switch e.verdict.source {
        case .cloud: e.v == YouTubeFeed.version
        case .model: e.v == YouTubeFeed.version && !cloudUsable
        case .fallback: Date().timeIntervalSince(e.at) < 3600
        default: false
        }
    }

    private var cloudUsable: Bool { Coach.enabled && Date() >= cloudDownUntil }

    private func drain() async {
        while !pending.isEmpty {
            if cloudUsable, let client = Coach.client {
                let batch = Array(pending.prefix(40))
                pending.removeFirst(batch.count)
                if let answers = await runCloud(batch, client: client) {
                    for (v, answer) in zip(batch, answers) {
                        let verdict: YouTubeFeed.Verdict
                        if let answer { verdict = answer } else { verdict = await local(v) }
                        record(v, verdict)
                    }
                    continue
                }
                pending.insert(contentsOf: batch.filter { working.contains($0.id) }, at: 0)
            }
            let v = pending.removeFirst()
            record(v, await local(v))
        }
        draining = false
    }

    private func record(_ v: YouTubeFeed.Video, _ verdict: YouTubeFeed.Verdict) {
        guard working.contains(v.id) else { return }
        verdicts[v.id] = Entry(verdict: verdict, channel: v.channel, title: v.title, v: YouTubeFeed.version, at: Date())
        working.remove(v.id)
        dirty = true
        save()
    }

    private func runCloud(_ batch: [YouTubeFeed.Video], client: XAIClient) async -> [YouTubeFeed.Verdict?]? {
        let model = XAIClient.Model.fast
        let system = YouTubeFeed.cloudSystem, text = YouTubeFeed.cloudPrompt(batch)
        let maxOut = 200 + 25 * batch.count
        let estimate = XAIClient.estimateUSD(model: model, text: system + text, images: 0, maxOutputTokens: maxOut)
        do {
            let reply = try await Coach.budget.run(estimateUSD: estimate, model: model, purpose: "youtube-feed") {
                try await client.complete(model: model, system: system, text: text,
                                          schema: YouTubeFeed.cloudSchema(count: batch.count), maxOutputTokens: maxOut, timeout: 30)
            }
            guard let answers = YouTubeFeed.parseCloud(reply.json, count: batch.count) else { throw XAIClient.Failure.malformed }
            return answers
        } catch {
            modelFailures += 1
            lastModelError = "cloud: " + String(String(describing: error).prefix(300)) + " (\(batch.count) videos)"
            if case XAIClient.Failure.overBudget = error {
                cloudDownUntil = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
            } else {
                cloudDownUntil = Date().addingTimeInterval(600)
            }
            return nil
        }
    }

    /// The on-device model, one video at a time; after three misses in a row, keywords for a while.
    private func local(_ v: YouTubeFeed.Video) async -> YouTubeFeed.Verdict {
        guard #available(macOS 26.0, *), Date() >= localDownUntil else { return YouTubeFeed.fallback(v) }
        let result: Result<YouTubeFeed.Verdict, Error>? = await Self.within(localMisses == 0 && !localWarm ? 90 : 20) {
            do { return .success(try await YouTubeFeed.judge(v)) } catch { return .failure(error) }
        }
        if case .success(let verdict)? = result {
            localMisses = 0
            localWarm = true
            return verdict
        }
        modelFailures += 1
        localMisses += 1
        if case .failure(let error)? = result { lastModelError = String(String(describing: error).prefix(300)) + " (on device)" }
        else { lastModelError = "on device: timed out" }
        if localMisses >= 3 {
            localMisses = 0
            localDownUntil = Date().addingTimeInterval(120)
        }
        return YouTubeFeed.fallback(v)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { c in
            let task = Task { let r = await work(); if once.claim() { c.resume(returning: r) } }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { task.cancel(); c.resume(returning: nil) }
            }
        }
    }
}
