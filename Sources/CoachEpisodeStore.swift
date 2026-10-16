import AppKit
import Combine
import ImageIO
import FocusCore

@MainActor
final class CoachEpisodeStore: ObservableObject {
    static let shared = CoachEpisodeStore()
    static let dryRunKey = "coachEpisodesDryRun"
    static let enabledKey = "coachEpisodesEnabled"
    @Published private(set) var status = "Not started"
    @Published private(set) var lastError: String?
    private let root: URL
    private let queue: CoachEpisodeQueue?
    private var timer: Timer?
    private var runner: Task<Void, Never>?
    private var enqueuer: Task<Void, Never>?
    private var generation = 0
    private var checkpoint: CoachEpisode.Checkpoint?
    private var previousText: String?
    private var started = false
    var dryRun: Bool { UserDefaults.standard.object(forKey: Self.dryRunKey) as? Bool ?? false }

    init(root: URL? = nil) {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Focus")
        self.root = root
        do {
            queue = try CoachEpisodeQueue(directory: root.appendingPathComponent("coach/episode-worker"),
                                           recordsDirectory: root.appendingPathComponent("episodes"),
                                           previewsDirectory: root.appendingPathComponent("coach/preview"))
        } catch { queue = nil; lastError = "Episode queue unavailable: \(error.localizedDescription)" }
    }
    func start() {
        guard !started, let queue else { return }
        started = true
        Task {
            if let latest = await queue.latestJob(), let source = try? await source(latest) {
                checkpoint = .init(row: source.row, visualHash: Self.visualHash(source.image))
                previousText = source.text
            }
            ScreenJournalStore.shared.onStored = { [weak self] in self?.observe($0) }
            drain()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
    }
    func invalidate() {
        generation += 1
        runner?.cancel()
        enqueuer?.cancel()
        checkpoint = nil; previousText = nil
    }
    func delete(bundle: String? = nil) {
        invalidate()
        guard let queue else { return }
        Task {
            do { try await queue.remove(bundle: bundle); status = "Deleted AI evidence" }
            catch { lastError = "Couldn't delete AI evidence: \(error.localizedDescription)" }
        }
    }
    private var enabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true)
            && (UserDefaults.standard.object(forKey: "screenWatch") as? Bool ?? true)
            && ScreenJournalStore.shared.enabled && ScreenEvidenceStore.shared.enabled
    }
    private func allowed(_ row: ScreenJournal.Row) -> Bool {
        enabled && row.cloudEligible && !ScreenWatcher.privateApps.contains(row.bundle)
            && ScreenWatcher.userIgnored[row.bundle] == nil && row.bundle != ScreenWatcher.ownBundle
            && row.at >= Date().addingTimeInterval(-7 * 86400)
    }
    private func observe(_ row: ScreenJournal.Row) {
        guard allowed(row), let text = row.text, let queue else { return }
        let token = generation
        let prior = enqueuer
        enqueuer = Task {
            await prior?.value
            guard !Task.isCancelled, token == generation, allowed(row),
                  let image = await image(row), token == generation, allowed(row) else { return }
            let fingerprint = Self.visualHash(image)
            guard CoachEpisode.meaningful(row: row, text: text, visualHash: fingerprint, previous: checkpoint, previousText: previousText) else { return }
            do {
                try await queue.enqueue(row: row, visualHash: fingerprint)
                checkpoint = .init(row: row, visualHash: fingerprint)
                previousText = text
                drain()
            } catch { lastError = "Couldn't queue episode: \(error.localizedDescription)" }
        }
    }
    private func image(_ row: ScreenJournal.Row) async -> Data? {
        guard let id = row.evidenceImageID else { return nil }
        let entries = await ScreenEvidenceStore.shared.entries(from: row.at.addingTimeInterval(-1), to: row.at.addingTimeInterval(1), bundles: [row.bundle])
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return await ScreenEvidenceStore.shared.imageData(for: entry)
    }
    private func source(_ job: CoachEpisodeQueue.Job) async throws -> (row: ScreenJournal.Row, text: String, image: Data)? {
        let folder = root.appendingPathComponent("journal")
        let found = try await Task.detached(priority: .utility) {
            try ScreenJournalReader.find(id: job.id, day: job.at, directory: folder)
        }.value
        guard let found, allowed(found.row),
              CoachEpisode.sourceAllowed(row: found.row, text: found.text),
              let image = await image(found.row), image.count <= 8 * 1024 * 1024,
              Data(found.text.utf8).count <= 1024 * 1024, allowed(found.row) else { return nil }
        return (found.row, found.text, image)
    }
    private func drain() {
        guard enabled, let queue, runner == nil else { return }
        let token = generation
        runner = Task {
            defer { runner = nil }
            for _ in 0..<8 {
                guard !Task.isCancelled, token == generation, enabled,
                      let job = await queue.next(includePreviews: !dryRun) else { return }
                do {
                    guard let source = try await source(job) else { try await queue.set(job.id, phase: .skipped); continue }
                    guard !Task.isCancelled, token == generation, allowed(source.row) else { return }
                    let prefixes = ClassCalendar.shared.coursePrefixes
                    let text = try CoachEpisode.prompt(row: source.row, text: source.text, coursePrefixes: prefixes)
                    if dryRun {
                        try await queue.preview(job.id, payload: CoachEpisode.preview(row: source.row, text: source.text, image: source.image, coursePrefixes: prefixes))
                        status = "Dry run: payload ready, nothing sent"
                        continue
                    }
                    guard Coach.enabled else { status = "Cloud AI is turned off"; return }
                    guard let client = Coach.client else { status = "Add an xAI key to enable understanding"; return }
                    try await queue.set(job.id, phase: .inFlight)
                    guard !Task.isCancelled, token == generation, allowed(source.row) else { return }
                    status = "Understanding a screen change"
                    let images = [source.image]
                    let estimate = XAIClient.estimateUSD(model: XAIClient.Model.fast, text: text, images: images.count, maxOutputTokens: 3500)
                    let fast = try await Coach.budget.run(estimateUSD: estimate, model: XAIClient.Model.fast, purpose: "episode:\(job.id.uuidString)") {
                        guard await MainActor.run(body: { token == self.generation && self.allowed(source.row) }), !Task.isCancelled else { throw CancellationError() }
                        return try await client.complete(model: XAIClient.Model.fast, system: CoachEpisode.system, text: text,
                                                  images: images, schema: CoachEpisode.schema, maxOutputTokens: 3500)
                    }
                    var understanding = try CoachEpisode.decode(fast.json)
                    var model = fast.model, usage = [fast.usage]
                    var needsReview = understanding.unreadable || understanding.confidence == .low
                    guard !Task.isCancelled, token == generation, allowed(source.row) else { return }
                    if understanding.needsStrongPass {
                        do {
                            let estimate = XAIClient.estimateUSD(model: XAIClient.Model.strong, text: text, images: images.count, maxOutputTokens: 5000, reasoningEffort: "low")
                            let strong = try await Coach.budget.run(estimateUSD: estimate, model: XAIClient.Model.strong, purpose: "episode-strong:\(job.id.uuidString)") {
                                guard await MainActor.run(body: { token == self.generation && self.allowed(source.row) }), !Task.isCancelled else { throw CancellationError() }
                                return try await client.complete(model: XAIClient.Model.strong, system: CoachEpisode.system, text: text,
                                    images: images, schema: CoachEpisode.schema, reasoningEffort: "low", maxOutputTokens: 5000)
                            }
                            usage.append(strong.usage)
                            understanding = try CoachEpisode.decode(strong.json); model = strong.model
                            needsReview = understanding.unreadable || understanding.confidence == .low
                        } catch { needsReview = true }
                    }
                    guard !Task.isCancelled, token == generation, allowed(source.row) else { return }
                    try await queue.finish(.init(source: source.row, understanding: understanding, model: model, usage: usage, needsReview: needsReview))
                    status = needsReview ? "Episode saved; evidence needs review" : "Episode saved"
                    lastError = nil
                } catch let error as XAIClient.Failure {
                    do {
                        switch error {
                        case .overBudget: try await queue.set(job.id, phase: .budget, retryAfter: Date().addingTimeInterval(300)); status = "Cloud paused at daily budget"
                        case .http(let status, _) where status >= 400 && status < 500:
                            try await queue.set(job.id, phase: .failed); lastError = "Cloud request refused (\(status)); no automatic retry"
                        default: try await queue.set(job.id, phase: .unknown); lastError = "Cloud outcome uncertain; no automatic retry"
                        }
                    } catch { lastError = "Couldn't save episode status: \(error.localizedDescription)" }
                } catch {
                    try? await queue.set(job.id, phase: .unknown)
                    lastError = "Episode paused: \(error.localizedDescription)"
                }
            }
        }
    }
    private static func visualHash(_ data: Data) -> UInt64? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 72)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            var hash: UInt64 = 0
            let pixels = bytes.bindMemory(to: UInt8.self)
            for y in 0..<8 { for x in 0..<8 { if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 << (y * 8 + x) } } }
            return hash
        }
    }
}
