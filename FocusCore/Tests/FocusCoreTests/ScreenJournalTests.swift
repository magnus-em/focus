import XCTest
@testable import FocusCore

final class ScreenJournalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ text: String, bundle: String = "app", offset: Double = 0, privacy: ScreenJournal.Privacy = .notBrowser) -> ScreenJournal.Row {
        let at = now.addingTimeInterval(offset)
        return .init(at: at, end: at.addingTimeInterval(15), app: "App", bundle: bundle, windowID: "1",
                     title: "Window", url: nil, category: "Admin", trackedCategory: "Admin", active: true,
                     idleSeconds: 0, privacy: privacy, evidenceImageID: nil, text: text)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func verify(_ directory: URL) throws -> [ScreenJournal.Row] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var rows: [ScreenJournal.Row] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
            var bases: [String: (row: ScreenJournal.Row, text: String)] = [:]
            for data in try Data(contentsOf: file).split(separator: 10) {
                let row = try decoder.decode(ScreenJournal.Row.self, from: Data(data))
                let text = try XCTUnwrap(ScreenJournal.reconstruct(row, base: bases[row.windowKey]))
                bases[row.windowKey] = (row, text); rows.append(row)
            }
        }
        return rows
    }

    func testFullTextUnicodeAndTrailingNewlinesRoundTripWithoutTruncation() {
        let old = String(repeating: "α ⊆ β\n", count: 1500) + "old\n"
        let new = String(repeating: "α ⊆ β\n", count: 1500) + "new\n"
        let base = row(old)
        var delta = row(new, offset: 15)
        delta.text = nil; delta.baseID = base.id; delta.delta = ScreenJournal.difference(from: old, to: new)
        XCTAssertEqual(ScreenJournal.reconstruct(delta, base: (base, old)), new)
        XCTAssertNil(ScreenJournal.reconstruct(delta, base: nil))
        XCTAssertNil(ScreenJournal.reconstruct(delta, base: (row(old), old)))
        XCTAssertNil(ScreenJournal.reconstruct(delta, base: (base, "wrong")))
        XCTAssertEqual(ScreenJournal.reconstruct(row(""), base: nil), "")
    }

    func testRotationAndRestartKeepEveryRetainedChunkReconstructable() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ScreenJournalWriter(directory: folder, byteBudget: 20_000, chunkBytes: 1800)
        for i in 0..<12 {
            try await writer.append(row(String(repeating: "line\n", count: 40) + "\(i)", offset: Double(i)), token: writer.token, now: now.addingTimeInterval(100))
        }
        let rows = try verify(folder)
        XCTAssertEqual(rows.count, 12)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.contains(".part") })
        let current = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { !$0.lastPathComponent.contains(".part") })
        let handle = try FileHandle(forWritingTo: current); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken tail".utf8)); try handle.close()
        let restarted = ScreenJournalWriter(directory: folder, byteBudget: 20_000, chunkBytes: 1800)
        try await restarted.append(row("after restart", offset: 30), token: restarted.token, now: now.addingTimeInterval(100))
        XCTAssertEqual(try verify(folder).count, 13)
    }

    func testQuotaRetentionAndInvalidatedWritesAreBounded() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ScreenJournalWriter(directory: folder, byteBudget: 3500, chunkBytes: 1200)
        let stale = writer.token; writer.invalidate()
        try await writer.append(row("must never persist"), token: stale, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        for i in 0..<20 {
            try await writer.append(row(String(repeating: "\(i)", count: 120), offset: Double(i)), token: writer.token, now: now.addingTimeInterval(100))
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(size, 3500)
        XCTAssertFalse(try verify(folder).isEmpty)
        try await writer.prune(now: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0)
    }

    func testBundleDeletionRebasesSurvivorsAndDeleteAllInvalidates() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ScreenJournalWriter(directory: folder)
        for i in 0..<5 {
            try await writer.append(row(String(repeating: "same\n", count: 20) + "\(i)", bundle: "allowed", offset: Double(i)), token: writer.token, now: now.addingTimeInterval(100))
            try await writer.append(row("removed", bundle: "private-later", offset: Double(i)), token: writer.token, now: now.addingTimeInterval(100))
        }
        try await writer.delete(bundle: "private-later")
        XCTAssertEqual(try verify(folder).count, 5)
        XCTAssertTrue(try verify(folder).allSatisfy { $0.bundle == "allowed" })
        let stale = writer.token
        try await writer.deleteAll()
        try await writer.append(row("pending"), token: stale, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testBrowserPrivacyFailsClosed() {
        XCTAssertFalse(row("x", privacy: .unknown).cloudEligible)
        XCTAssertFalse(row("x", privacy: .incognito).cloudEligible)
        XCTAssertTrue(row("x", privacy: .regular).cloudEligible)
        XCTAssertTrue(row("x").cloudEligible)
    }
}
