import FocusCore
import os
import ReplayKit
import UIKit
import Vision

/// Screen broadcast ("Focus Screen Notes" in Control Center → Screen
/// Recording): every 15s one frame is read on-device with Vision, labeled and
/// turned into study notes by the on-device model, and the current block
/// (title + notes) is sent to the Mac. Frames and text never leave the iPad.
final class SampleHandler: RPBroadcastSampleHandler {
    private let notes = BroadcastNotes()
    private let queue = DispatchQueue(label: "focus.broadcast.ocr", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: (last: Date.distantPast, busy: false))

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard BroadcastNotes.modelAvailable else {
            finishBroadcastWithError(NSError(domain: "Focus", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screen notes need Apple Intelligence on this device.",
            ]))
            return
        }
    }

    override func broadcastFinished() {
        let done = DispatchSemaphore(value: 0)
        Task { await notes.finish(); done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let go = state.withLock { s -> Bool in
            guard !s.busy, Date().timeIntervalSince(s.last) >= 15 else { return false }
            s = (Date(), true)
            return true
        }
        guard go else { return }
        let raw = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value
        let orientation = raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        queue.async { [notes, state] in
            let text = Self.recognize(pixels, orientation: orientation)
            Task {
                await notes.add(text: text, at: Date())
                state.withLock { $0.busy = false }
            }
        }
    }

    private static func recognize(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(1500))
    }
}

/// One block per stretch of the same category. A category change only counts
/// after 3 snapshots in a row agree, so the small model's flips don't split it.
actor BroadcastNotes {
    private struct Block {
        var id: String
        var start: Date
        var end: Date
        var category: String?
        var title = ""
        var bullets: [String] = []
        var pages: [(date: Date, text: String)] = []
        var notedThrough = Date.distantPast
        var notedAt = Date.distantPast
        var savedAt = Date.distantPast
    }

    private var block: Block?
    private var pending: (category: String, since: Date, count: Int)?
    private let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    /// Same set as the Mac's `ScreenWatcher.offScreenCategories`.
    private static let offScreen: Set<String> = ["Sleep", "Meals", "Exercise", "Commute", "Chores"]

    static var modelAvailable: Bool {
        if #available(iOS 26.0, *) { return ScreenLabeler.modelAvailable }
        return false
    }

    private var categories: [String] {
        (UserDefaults(suiteName: "group.com.magnus.focus")?.stringArray(forKey: "tags") ?? [])
            .filter { !Self.offScreen.contains($0) }
    }

    func add(text: String, at now: Date) async {
        guard #available(iOS 26.0, *), text.count >= 40 else { return }
        let label = await ScreenLabeler.classify(app: "\(device) screen", title: "", text: text, categories: categories)
        let category = label?.0

        if var b = block, now.timeIntervalSince(b.end) > 5 * 60 {
            b.end = b.end.addingTimeInterval(15)
            block = b
            await close()
        }
        if block == nil { block = Block(id: "\(device)-\(Int(now.timeIntervalSince1970))", start: now, end: now, category: category) }

        if let c = category, c != block?.category {
            if let p = pending, p.category == c { pending = (c, p.since, p.count + 1) } else { pending = (c, now, 1) }
            if let p = pending, p.count >= 3 || block?.category == nil {
                let carried = block?.pages.filter { $0.date >= p.since } ?? []
                block?.pages.removeAll { $0.date >= p.since }
                block?.end = p.since
                await close()
                block = Block(id: "\(device)-\(Int(p.since.timeIntervalSince1970))", start: p.since, end: now,
                              category: c, pages: carried)
                pending = nil
            }
        } else {
            pending = nil
        }

        guard var b = block else { return }
        b.end = now
        if !b.pages.contains(where: { $0.text == text }) { b.pages.append((now, text)) }
        b.pages.removeAll { now.timeIntervalSince($0.date) > 4 * 3600 }
        block = b
        if now.timeIntervalSince(b.notedAt) >= 90, now.timeIntervalSince(b.start) >= 90 { await writeNotes() }
        if now.timeIntervalSince(block?.savedAt ?? .distantPast) >= 60 { await save() }
    }

    func finish() async {
        await close()
    }

    private func close() async {
        guard block != nil else { return }
        await writeNotes()
        await save()
        block = nil
        pending = nil
    }

    private func writeNotes() async {
        guard #available(iOS 26.0, *), var b = block else { return }
        let fresh = b.pages.filter { $0.date > b.notedThrough }
        guard !fresh.isEmpty else { return }
        let previous: (String, [String])? = b.title.isEmpty ? nil : (b.title, b.bullets)
        if let (title, bullets) = await ScreenLabeler.studyNotes(
            category: b.category ?? "Unlabeled", windows: ["\(device) screen"], previous: previous,
            pages: fresh.map { ("\(device) screen", $0.text) }
        ) {
            b.title = title
            b.bullets = bullets
            b.notedThrough = fresh.map(\.date).max() ?? b.notedThrough
        }
        b.notedAt = Date()
        block = b
    }

    private func save() async {
        guard var b = block, b.end.timeIntervalSince(b.start) >= 60 else { return }
        try? await DeviceActivityCloud.save(DeviceActivity(
            id: b.id, kind: .block, device: device, app: "\(device) screen", date: b.start, end: b.end,
            category: b.category, title: b.title.isEmpty ? "\(device) screen" : b.title, bullets: b.bullets
        ))
        b.savedAt = Date()
        block = b
    }
}
