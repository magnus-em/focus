import AppKit
import FocusCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenEvidenceStore: ObservableObject {
    static let shared = ScreenEvidenceStore()
    static let enabledKey = "screenEvidenceEnabled"

    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let at: Date
        let bundle: String
        let title: String
        let bytes: Int
    }

    @Published var enabled: Bool {
        didSet {
            worker.invalidatePendingRecords()
            CoachEpisodeStore.shared.invalidate()
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        }
    }
    @Published private(set) var revision = 0
    @Published private(set) var storedBytes = 0
    @Published private(set) var count = 0
    @Published private(set) var lastError: String?
    @Published private(set) var deleting = false
    private let worker: ScreenEvidenceWorker
    private var retentionTimer: Timer?

    init(directory: URL? = nil) {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        worker = ScreenEvidenceWorker(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/screen-evidence", isDirectory: true))
        refresh()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func record(image: CGImage, at: Date, bundle: String, title: String) async -> UUID? {
        guard enabled, !deleting, !ScreenWatcher.privateApps.contains(bundle), ScreenWatcher.userIgnored[bundle] == nil,
              bundle != ScreenWatcher.ownBundle else { return nil }
        let generation = worker.recordGeneration
        let result = await worker.record(image: image, at: at, bundle: bundle, title: title, generation: generation)
        update(result)
        guard enabled, !deleting, generation == worker.recordGeneration,
              !ScreenWatcher.privateApps.contains(bundle), ScreenWatcher.userIgnored[bundle] == nil else { return nil }
        return result.savedID
    }

    func entries(from: Date, to: Date, bundles: Set<String>? = nil) async -> [Entry] {
        let excluded = ScreenWatcher.privateApps.union(ScreenWatcher.userIgnored.keys).union([ScreenWatcher.ownBundle])
        return await worker.entries(from: from, to: to, bundles: bundles, excluding: excluded)
    }

    func thumbnail(for entry: Entry, maxPixelSize: Int = 1400) async -> CGImage? {
        await worker.thumbnail(for: entry, maxPixelSize: maxPixelSize)
    }

    func imageData(for entry: Entry) async -> Data? {
        let generation = worker.recordGeneration
        guard enabled, !deleting, !ScreenWatcher.privateApps.contains(entry.bundle), ScreenWatcher.userIgnored[entry.bundle] == nil,
              entry.bundle != ScreenWatcher.ownBundle else { return nil }
        let data = await worker.imageData(for: entry)
        guard enabled, !deleting, generation == worker.recordGeneration,
              !ScreenWatcher.privateApps.contains(entry.bundle), ScreenWatcher.userIgnored[entry.bundle] == nil else { return nil }
        return data
    }

    func deleteAll() {
        guard !deleting else { return }
        deleting = true
        worker.invalidatePendingRecords()
        ScreenJournalStore.shared.deleteAll()
        revision &+= 1
        let worker = worker
        Task {
            update(await worker.deleteAll())
            deleting = false
        }
    }

    func delete(bundle: String) {
        worker.invalidatePendingRecords()
        ScreenJournalStore.shared.delete(bundle: bundle)
        revision &+= 1
        let worker = worker
        Task { update(await worker.delete(bundle: bundle)) }
    }

    private func refresh() {
        let worker = worker
        Task { update(await worker.state()) }
    }

    private func update(_ state: ScreenEvidenceWorker.State) {
        storedBytes = state.bytes
        count = state.count
        lastError = state.error
        revision &+= 1
    }
}

final class ScreenEvidenceWorker: @unchecked Sendable {
    typealias Entry = ScreenEvidenceStore.Entry
    struct State: Sendable {
        var bytes: Int
        var count: Int
        var error: String?
        var savedID: UUID? = nil
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "com.magnus.focus.screen-evidence", qos: .utility)
    private let keepSeconds: TimeInterval
    private let byteBudget: Int
    private var index: [Entry] = []
    private var loaded = false
    private var error: String?
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    var recordGeneration: UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    func invalidatePendingRecords() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
    }

    init(directory: URL, keepSeconds: TimeInterval = 7 * 86400, byteBudget: Int = 256 * 1024 * 1024) {
        self.directory = directory
        self.keepSeconds = keepSeconds
        self.byteBudget = byteBudget
    }

    func record(image: CGImage, at: Date, bundle: String, title: String, generation: UInt64? = nil) async -> State {
        let expectedGeneration = generation ?? recordGeneration
        return await perform {
            guard expectedGeneration == self.recordGeneration else { return self.snapshot }
            var savedID: UUID?
            do {
                try self.load()
                let id = UUID()
                let image = self.resized(image, maxPixelSize: 1600)
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                guard expectedGeneration == self.recordGeneration else { return self.snapshot }
                try (data as Data).write(to: self.url(id), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url(id).path)
                guard expectedGeneration == self.recordGeneration else {
                    try FileManager.default.removeItem(at: self.url(id))
                    return self.snapshot
                }
                self.index.append(Entry(id: id, at: at, bundle: bundle, title: String(title.prefix(240)), bytes: data.length))
                try self.prune(now: Date())
                try self.save()
                if expectedGeneration != self.recordGeneration {
                    self.index.removeAll { $0.id == id }
                    if FileManager.default.fileExists(atPath: self.url(id).path) {
                        try FileManager.default.removeItem(at: self.url(id))
                    }
                    try self.save()
                }
                if expectedGeneration == self.recordGeneration, self.index.contains(where: { $0.id == id }) { savedID = id }
                self.error = nil
            } catch { self.error = "Couldn't save screen evidence: \(error.localizedDescription)" }
            var state = self.snapshot
            state.savedID = savedID
            return state
        }
    }

    func entries(from: Date, to: Date, bundles: Set<String>?, excluding: Set<String>) async -> [Entry] {
        await perform {
            do { try self.load() } catch { return [] }
            let cutoff = Date().addingTimeInterval(-self.keepSeconds)
            return self.index.filter {
                $0.at >= max(from, cutoff) && $0.at < to && !excluding.contains($0.bundle)
                    && (bundles == nil || bundles!.contains($0.bundle))
            }.sorted { $0.at < $1.at }
        }
    }

    func thumbnail(for entry: Entry, maxPixelSize: Int) async -> CGImage? {
        await perform {
            guard entry.at >= Date().addingTimeInterval(-self.keepSeconds),
                  let source = CGImageSourceCreateWithURL(self.url(entry.id) as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(maxPixelSize, 100), 1600),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
    }

    func imageData(for entry: Entry) async -> Data? {
        await perform {
            do { try self.load() } catch { return nil }
            guard entry.at >= Date().addingTimeInterval(-self.keepSeconds), self.index.contains(where: { $0.id == entry.id }) else { return nil }
            return try? Data(contentsOf: self.url(entry.id))
        }
    }

    func state() async -> State {
        await perform {
            do {
                try self.load()
                try self.prune(now: Date())
                try self.save()
            } catch { self.error = error.localizedDescription }
            return self.snapshot
        }
    }

    func deleteAll() async -> State {
        await perform {
            do {
                if FileManager.default.fileExists(atPath: self.directory.path) {
                    try FileManager.default.removeItem(at: self.directory)
                }
                self.index = []
                self.loaded = false
                try self.load()
                self.error = nil
            } catch { self.error = "Couldn't delete screen evidence: \(error.localizedDescription)" }
            return self.snapshot
        }
    }

    func delete(bundle: String) async -> State {
        await perform {
            do {
                try self.load()
                for entry in self.index where entry.bundle == bundle {
                    try FileManager.default.removeItem(at: self.url(entry.id))
                }
                self.index.removeAll { $0.bundle == bundle }
                try self.save()
                self.error = nil
            } catch { self.error = "Couldn't delete screen evidence: \(error.localizedDescription)" }
            return self.snapshot
        }
    }

    private var snapshot: State { State(bytes: index.reduce(0) { $0 + $1.bytes }, count: index.count, error: error) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }

    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: indexURL.path) {
            index = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: indexURL))) ?? []
        }
        index = index.filter { FileManager.default.fileExists(atPath: url($0.id).path) }
        let names = Set(index.map { "\($0.id.uuidString).jpg" })
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "jpg" && !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
        try prune(now: Date())
        try save()
        loaded = true
    }

    private func prune(now: Date) throws {
        index.sort { $0.at < $1.at }
        var bytes = index.reduce(0) { $0 + $1.bytes }
        let cutoff = now.addingTimeInterval(-keepSeconds)
        while let first = index.first, first.at < cutoff || bytes > byteBudget || index.count > 12000 {
            try FileManager.default.removeItem(at: url(first.id))
            bytes -= first.bytes
            index.removeFirst()
        }
    }

    private func save() throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func resized(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let scale = min(1, Double(maxPixelSize) / Double(max(image.width, image.height)))
        guard scale < 1, let context = CGContext(data: nil, width: max(1, Int(Double(image.width) * scale)),
                                               height: max(1, Int(Double(image.height) * scale)), bitsPerComponent: 8,
                                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}
