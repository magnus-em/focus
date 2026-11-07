import Foundation
import FocusCore

/// App side of `YouTubeFeed`: remembers every verdict by video id
/// (`Focus/youtube/verdicts.json`, newest 6000) and the user's channel rules
/// (`Focus/youtube/channels.json`), and runs the model one batch at a time.
actor YouTubeFeedFilter {
    static let shared = YouTubeFeedFilter()

    private struct Entry: Codable { var verdict: YouTubeFeed.Verdict; var channel: String; var at: Date }

    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/youtube", isDirectory: true)
    private var verdicts: [String: Entry] = [:]
    private var rules: [String: Bool] = [:]
    private var loaded = false
    private var dirty = false
    private var modelBusy = false
    private var modelWaiters: [CheckedContinuation<Void, Never>] = []
    private var modelPausedUntil = Date.distantPast

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

    func classify(_ videos: [YouTubeFeed.Video]) async -> [String: YouTubeFeed.Verdict] {
        load()
        var out: [String: YouTubeFeed.Verdict] = [:]
        var ask: [YouTubeFeed.Video] = []
        for v in videos.prefix(60) where out[v.id] == nil {
            if let quick = YouTubeFeed.quick(v, rules: rules) {
                out[v.id] = quick
            } else if let cached = verdicts[v.id], cached.verdict.source != .fallback {
                out[v.id] = cached.verdict
            } else if !ask.contains(where: { $0.id == v.id }) {
                ask.append(v)
            }
        }
        for start in stride(from: 0, to: ask.count, by: 8) {
            let batch = Array(ask[start..<min(start + 8, ask.count)])
            let answers = await runModel(batch)
            for (i, v) in batch.enumerated() {
                let verdict = answers.map { YouTubeFeed.Verdict(keep: $0[i], source: .model) } ?? YouTubeFeed.fallback(v)
                out[v.id] = verdict
                verdicts[v.id] = Entry(verdict: verdict, channel: v.channel, at: Date())
                dirty = true
            }
        }
        save()
        return out
    }

    private func runModel(_ batch: [YouTubeFeed.Video]) async -> [Bool]? {
        guard #available(macOS 26.0, *) else { return nil }
        while modelBusy { await withCheckedContinuation { modelWaiters.append($0) } }
        guard Date() >= modelPausedUntil else { return nil }
        modelBusy = true
        defer {
            modelBusy = false
            if !modelWaiters.isEmpty { modelWaiters.removeFirst().resume() }
        }
        // On 11/7 one respond(to:) never returned, and every later request queued behind it,
        // so YouTube showed "Focus isn't reachable" until the app restarted.
        let answers = await Self.within(20) { await YouTubeFeed.classify(batch) }
        if answers == nil { modelPausedUntil = Date().addingTimeInterval(120) }
        return answers
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
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
