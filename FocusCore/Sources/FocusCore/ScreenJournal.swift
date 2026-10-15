import Foundation
import CryptoKit

public enum ScreenJournal {
    public enum Privacy: String, Codable, Sendable { case notBrowser = "not-browser", regular, incognito, unknown }
    public struct Delta: Codable, Equatable, Sendable {
        public let prefixLines: Int, suffixLines: Int
        public let lines: [String]
    }
    public struct Row: Codable, Sendable {
        public var schema = 1
        public let id: UUID
        public let at: Date, end: Date
        public let app: String, bundle: String, windowID: String, title: String
        public let url: String?, category: String?, trackedCategory: String?
        public let active: Bool
        public let idleSeconds: Double
        public let privacy: Privacy
        public let evidenceImageID: UUID?
        public let textHash: String
        public var text: String?
        public var baseID: UUID?
        public var delta: Delta?

        public init(id: UUID = UUID(), at: Date, end: Date, app: String, bundle: String, windowID: String,
                    title: String, url: String?, category: String?, trackedCategory: String?, active: Bool,
                    idleSeconds: Double, privacy: Privacy, evidenceImageID: UUID?, text: String) {
            self.id = id; self.at = at; self.end = end; self.app = app; self.bundle = bundle
            self.windowID = windowID; self.title = title; self.url = url; self.category = category
            self.trackedCategory = trackedCategory; self.active = active; self.idleSeconds = idleSeconds
            self.privacy = privacy; self.evidenceImageID = evidenceImageID
            self.textHash = ScreenJournal.hash(text); self.text = text
        }
        public var windowKey: String { bundle + "|" + windowID }
        public var cloudEligible: Bool { privacy == .notBrowser || privacy == .regular }
    }

    public static func hash(_ text: String) -> String {
        hash(Data(text.utf8))
    }
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func difference(from old: String, to new: String) -> Delta {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return Delta(prefixLines: prefix, suffixLines: suffix, lines: Array(b[prefix..<(b.count - suffix)]))
    }

    public static func reconstruct(_ row: Row, base: (row: Row, text: String)?) -> String? {
        guard row.schema == 1 else { return nil }
        let text: String
        if let full = row.text {
            guard row.baseID == nil, row.delta == nil else { return nil }
            text = full
        } else {
            guard let delta = row.delta, let base, row.baseID == base.row.id,
                  row.windowKey == base.row.windowKey,
                  delta.prefixLines >= 0, delta.suffixLines >= 0 else { return nil }
            let lines = base.text.components(separatedBy: "\n")
            guard delta.prefixLines <= lines.count, delta.suffixLines <= lines.count - delta.prefixLines else { return nil }
            text = (Array(lines.prefix(delta.prefixLines)) + delta.lines + Array(lines.suffix(delta.suffixLines))).joined(separator: "\n")
        }
        return hash(text) == row.textHash ? text : nil
    }
}

public final class ScreenJournalWriter: @unchecked Sendable {
    private let directory: URL
    private let keepSeconds: TimeInterval
    private let byteBudget: Int, chunkBytes: Int
    private let queue = DispatchQueue(label: "com.magnus.focus.screen-journal", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var current: URL?
    private var previous: [String: (row: ScreenJournal.Row, text: String)] = [:]
    private var previousBytes = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public init(directory: URL, keepSeconds: TimeInterval = 7 * 86400, byteBudget: Int = 128 * 1024 * 1024,
                chunkBytes: Int = 4 * 1024 * 1024) {
        self.directory = directory; self.keepSeconds = keepSeconds
        self.byteBudget = max(1, byteBudget); self.chunkBytes = max(1, min(chunkBytes, byteBudget))
    }
    public var token: Int { lock.lock(); defer { lock.unlock() }; return generation }
    public func invalidate() { lock.lock(); generation += 1; lock.unlock() }

    @discardableResult
    public func append(_ baseline: ScreenJournal.Row, token expected: Int, now: Date = Date()) async throws -> Bool {
        try await perform {
            guard self.token == expected else { return false }
            guard let text = baseline.text, baseline.at <= now, baseline.end >= baseline.at,
                  baseline.at >= now.addingTimeInterval(-self.keepSeconds), baseline.idleSeconds.isFinite else { return false }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let day = Self.dayKey(baseline.at)
            try self.pruneFiles(now: now)
            if self.current?.lastPathComponent != "\(day).jsonl" {
                self.current = self.directory.appendingPathComponent("\(day).jsonl")
                self.resetMemory()
                try self.repairTail(self.current!)
            }
            var row = baseline
            if let previous = self.previous[row.windowKey] {
                let delta = ScreenJournal.difference(from: previous.text, to: text)
                if try self.encoder.encode(delta).count < Data(text.utf8).count {
                    row.text = nil; row.baseID = previous.row.id; row.delta = delta
                }
            }
            var data = try self.encoder.encode(row); data.append(10)
            guard data.count <= self.byteBudget else { throw CocoaError(.fileWriteOutOfSpace) }
            let url = self.current!
            let oldBytes = try self.size(url)
            if oldBytes > 0, oldBytes + data.count > self.chunkBytes {
                let chunks = try self.files().filter { $0.lastPathComponent.hasPrefix(day + ".part") }
                let next = (chunks.compactMap { Int($0.deletingPathExtension().lastPathComponent.components(separatedBy: ".part").last ?? "") }.max() ?? 0) + 1
                let archive = self.directory.appendingPathComponent(String(format: "%@.part%06d.jsonl", day, next))
                try FileManager.default.moveItem(at: url, to: archive)
                self.resetMemory()
                row = baseline; data = try self.encoder.encode(row); data.append(10)
            }
            guard data.count <= self.byteBudget else { throw CocoaError(.fileWriteOutOfSpace) }
            try self.pruneFiles(now: now, reserving: data.count)
            if !FileManager.default.fileExists(atPath: url.path) {
                self.resetMemory()
                row = baseline; data = try self.encoder.encode(row); data.append(10)
                guard data.count <= self.byteBudget else { throw CocoaError(.fileWriteOutOfSpace) }
                try self.pruneFiles(now: now, reserving: data.count)
            }
            guard self.token == expected else { return false }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                } else { try data.write(to: url, options: .atomic) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                self.current = nil; self.resetMemory()
                throw error
            }
            if self.token != expected {
                try self.rewrite(excluding: { $0.id == row.id })
                self.resetMemory()
                return false
            }
            self.previousBytes -= self.previous[row.windowKey].map { Data($0.text.utf8).count } ?? 0
            self.previous[row.windowKey] = (row, text)
            self.previousBytes += Data(text.utf8).count
            if self.previous.count > 100 || self.previousBytes > 8 * 1024 * 1024 { self.resetMemory() }
            return true
        }
    }

    public func prune(now: Date = Date()) async throws { try await perform { try self.pruneFiles(now: now) } }
    public func deleteAll() async throws {
        invalidate()
        try await perform {
            if FileManager.default.fileExists(atPath: self.directory.path) { try FileManager.default.removeItem(at: self.directory) }
            self.current = nil; self.resetMemory()
        }
    }
    public func delete(bundle: String) async throws {
        invalidate()
        try await perform { try self.rewrite(excluding: { $0.bundle == bundle }); self.resetMemory() }
    }

    private func resetMemory() { previous.removeAll(); previousBytes = 0 }
    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private func size(_ file: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}(\.part\d+)?\.jsonl$"#, options: .regularExpression) != nil }
    }
    private func pruneFiles(now: Date, reserving bytes: Int = 0) throws {
        var files = try files().sorted {
            let a = $0.lastPathComponent, b = $1.lastPathComponent
            if a.prefix(10) != b.prefix(10) { return a.prefix(10) < b.prefix(10) }
            // The unnumbered file is the newest chunk for its day.
            if a.contains(".part") != b.contains(".part") { return a.contains(".part") }
            return a < b
        }
        let cutoff = Self.dayKey(now.addingTimeInterval(-keepSeconds))
        var total = try files.reduce(0) { try $0 + size($1) }
        while let first = files.first, first.lastPathComponent.prefix(10) <= cutoff || total + bytes > byteBudget {
            total -= try size(first)
            try FileManager.default.removeItem(at: first)
            if current == first { resetMemory() }
            files.removeFirst()
        }
    }
    private func rewrite(excluding excluded: (ScreenJournal.Row) -> Bool) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in try files() {
            let data = try Data(contentsOf: file)
            var bases: [String: (row: ScreenJournal.Row, text: String)] = [:]
            var keptBases: [String: (row: ScreenJournal.Row, text: String)] = [:]
            var output = Data()
            for line in data.split(separator: 10) {
                guard var row = try? decoder.decode(ScreenJournal.Row.self, from: Data(line)),
                      let text = ScreenJournal.reconstruct(row, base: bases[row.windowKey]) else { continue }
                bases[row.windowKey] = (row, text)
                guard !excluded(row) else { continue }
                row.text = text; row.baseID = nil; row.delta = nil
                if let previous = keptBases[row.windowKey] {
                    let delta = ScreenJournal.difference(from: previous.text, to: text)
                    if try encoder.encode(delta).count < Data(text.utf8).count {
                        row.text = nil; row.baseID = previous.row.id; row.delta = delta
                    }
                }
                keptBases[row.windowKey] = (row, text)
                output.append(try encoder.encode(row)); output.append(10)
            }
            if output.isEmpty { try FileManager.default.removeItem(at: file) }
            else {
                try output.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }
    private func repairTail(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.last != 10 else { return }
        let end = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
        try Data(data.prefix(end)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
