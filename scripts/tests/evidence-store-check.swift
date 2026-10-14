import AppKit

@MainActor
enum ScreenWatcher {
    static let privateApps: Set<String> = ["private"]
    static let userIgnored: [String: String] = [:]
    static let ownBundle = "own"
}

@main
struct EvidenceHarness {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-evidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = ScreenEvidenceWorker(directory: directory)
        let context = CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        let image = context.makeImage()!
        let now = Date()
        _ = await worker.record(image: image, at: now.addingTimeInterval(-30), bundle: "math", title: "Proofs")
        _ = await worker.record(image: image, at: now.addingTimeInterval(-20), bundle: "chat", title: "Math conversation")
        let state = await worker.record(image: image, at: now.addingTimeInterval(-10), bundle: "math", title: "Assignment")
        precondition(state.count == 3 && state.bytes > 0 && state.error == nil)
        let entries = await worker.entries(from: now.addingTimeInterval(-25), to: now, bundles: nil, excluding: [])
        precondition(entries.count == 2 && entries[0].title == "Math conversation")
        let filtered = await worker.entries(from: now.addingTimeInterval(-60), to: now, bundles: ["math"], excluding: [])
        precondition(filtered.count == 2)
        let excluded = await worker.entries(from: now.addingTimeInterval(-60), to: now, bundles: nil, excluding: ["chat"])
        precondition(excluded.count == 2)
        let thumbnail = await worker.thumbnail(for: entries[0], maxPixelSize: 200)!
        precondition(max(thumbnail.width, thumbnail.height) == 200)
        let old = await worker.record(image: image, at: now.addingTimeInterval(-8 * 86400), bundle: "old", title: "Expired")
        precondition(old.count == 3 && old.error == nil)
        let reloaded = ScreenEvidenceWorker(directory: directory)
        let persisted = await reloaded.state()
        precondition(persisted.count == 3 && persisted.bytes == state.bytes)
        let deleted = await worker.delete(bundle: "math")
        precondition(deleted.count == 1 && deleted.error == nil)
        let deletedEntries = await worker.entries(from: now.addingTimeInterval(-60), to: now, bundles: nil, excluding: [])
        precondition(deletedEntries.count == 1 && deletedEntries[0].bundle == "chat")
        let empty = await worker.deleteAll()
        precondition(empty.count == 0 && empty.bytes == 0 && empty.error == nil)
        let staleGeneration = worker.recordGeneration
        worker.invalidatePendingRecords()
        let canceled = await worker.record(image: image, at: now, bundle: "math", title: "Canceled capture", generation: staleGeneration)
        precondition(canceled.count == 0 && canceled.bytes == 0)
        let canceledFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(canceledFiles.allSatisfy { $0.pathExtension != "jpg" })
        let budgetWorker = ScreenEvidenceWorker(directory: directory.appendingPathComponent("budget"), byteBudget: 1)
        let bounded = await budgetWorker.record(image: image, at: now, bundle: "math", title: "Too big")
        precondition(bounded.count == 0 && bounded.bytes == 0 && bounded.error == nil)
        print("PASS: interval lookup, bundle filters/exclusions, thumbnail downsampling, seven-day pruning, index reload, ignore deletion, delete-all, cancellation generation, disk budget")
    }
}
