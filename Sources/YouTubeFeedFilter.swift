import Foundation
import FocusCore

/// App side of `YouTubeFeed`: remembers every verdict by video id
/// (`Focus/youtube/verdicts.json`, newest 6000, with the title so the rules can be tuned on real feeds)
/// and the user's channel rules (`Focus/youtube/channels.json`), and runs the model one batch at a time.
/// `Focus/youtube/page.json` holds the extension's latest page report and the last model error.
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

    private var verdictsURL: URL { dir.appendingPathComponent("verdicts.json") }
    private var rulesURL: URL { dir.appendingPathComponent("channels.json") }

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

    func note(page: Data) {
        guard var out = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any] else { return }
        out["at"] = ISO8601DateFormatter().string(from: Date())
        out["modelQueue"] = pending.count
        out["modelFailures"] = modelFailures
        if let lastModelError { out["lastModelError"] = lastModelError }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("page.json"), options: .atomic)
        }
    }

    /// Answers at once from rules and the cache; videos it doesn't know yet go to the model in the
    /// background and are missing from the reply, so the extension asks again. The model can take
    /// ~40 s to wake up (11/7), longer than the extension waits.
    func classify(_ videos: [YouTubeFeed.Video]) -> [String: YouTubeFeed.Verdict] {
        load()
        var out: [String: YouTubeFeed.Verdict] = [:]
        for v in videos.prefix(60) where out[v.id] == nil {
            if let quick = YouTubeFeed.quick(v, rules: rules) {
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

    private func fresh(_ e: Entry) -> Bool {
        switch e.verdict.source {
        case .model: e.v == YouTubeFeed.version
        case .fallback: Date().timeIntervalSince(e.at) < 3600
        default: false
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = Array(pending.prefix(8))
            pending.removeFirst(batch.count)
            var answers: [Bool?] = Array(repeating: nil, count: batch.count)
            var batched = false
            if let all = await runModel(batch, limit: 90) {
                answers = all.map { $0 }
                batched = true
            } else if batch.count > 1 {
                // One title can trip the model's guardrails and fail the whole batch (11/7: eight
                // videos at once fell back to keywords), so ask about each on its own.
                var misses = 0
                for (i, v) in batch.enumerated() where misses < 3 {
                    answers[i] = await runModel([v], limit: 20)?.first
                    if answers[i] == nil { misses += 1 }
                }
            }
            if batched, batch.count > 1 {
                // In a batch the 3B model lets through about half its keeps by mistake (11/7: Clash of
                // Clans, Flappy Bird, "birds for some reason"). A refusal or error keeps the batch's answer.
                for (i, v) in batch.enumerated() where answers[i] == true {
                    if let sure = await confirm(v), !sure { answers[i] = false }
                }
            }
            for (i, v) in batch.enumerated() {
                let verdict = answers[i].map { YouTubeFeed.Verdict(keep: $0, source: .model) } ?? YouTubeFeed.fallback(v)
                verdicts[v.id] = Entry(verdict: verdict, channel: v.channel, title: v.title, v: YouTubeFeed.version, at: Date())
                working.remove(v.id)
            }
            dirty = true
            save()
        }
        draining = false
    }

    private func runModel(_ batch: [YouTubeFeed.Video], limit: Double) async -> [Bool]? {
        guard #available(macOS 26.0, *) else { return nil }
        let result: Result<[Bool], Error>? = await Self.within(limit) {
            do { return .success(try await YouTubeFeed.classify(batch)) } catch { return .failure(error) }
        }
        switch result {
        case .success(let answers)?:
            return answers
        case .failure(let error)?:
            modelFailures += 1
            lastModelError = String(String(describing: error).prefix(300)) + " (\(batch.count) videos)"
            return nil
        case nil:
            modelFailures += 1
            lastModelError = "timed out after \(Int(limit)) s (\(batch.count) videos)"
            return nil
        }
    }

    private func confirm(_ video: YouTubeFeed.Video) async -> Bool? {
        guard #available(macOS 26.0, *) else { return nil }
        let result: Result<Bool, Error>? = await Self.within(20) {
            do { return .success(try await YouTubeFeed.confirm(video)) } catch { return .failure(error) }
        }
        if case .success(let sure)? = result { return sure }
        modelFailures += 1
        if case .failure(let error)? = result { lastModelError = String(String(describing: error).prefix(300)) + " (second look)" }
        return nil
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
