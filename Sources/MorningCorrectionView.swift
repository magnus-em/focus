import SwiftUI
import FocusCore

struct MorningCorrectionView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var settings: AppSettings
    let timer: TimerManager
    var preview = false

    private struct Receipt: Codable {
        let id: UUID
        let start: Date
        let end: Date
        let disposition: String
    }

    private struct Change {
        let candidate: MorningReviewPlanner.Candidate
        let receiptID: UUID
        let undo: SessionStore.ReviewUndo?
        let message: String
    }

    @State private var queue: [MorningReviewPlanner.Candidate] = []
    @State private var spans: [ScreenSpan] = []
    @State private var receipts: [Receipt] = []
    @State private var changes: [Change] = []
    @State private var loaded = false
    @State private var skipped = false
    @State private var error: String?
    @State private var reviewedCount = 0
    @State private var startingCount = 0

    private static let receiptsKey = "morningCorrectionReceipts"
    private static let skippedKey = "morningCorrectionSkippedDay"

    var body: some View {
        VStack(spacing: 0) {
            if loaded, !skipped, startingCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("A quick look at yesterday").font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 4)
                        Button("Skip") { skipToday() }
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .frame(minHeight: 36)
                            .buttonStyle(.plain).help("Leave yesterday as it is and continue with your commitment")
                    }
                    if let candidate = queue.first {
                        Text("\(reviewedCount + 1) of \(startingCount) · largest stretches first")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        card(candidate)
                    } else {
                        Label("Yesterday's quick review is done", systemImage: "checkmark.circle")
                            .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    }
                    if let change = changes.last {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(change.message).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            Spacer(minLength: 4)
                            Button("Undo") { undoLast() }
                                .font(.system(size: 13, weight: .semibold)).buttonStyle(.borderless)
                                .frame(minHeight: 36)
                        }
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
            }
        }
        .onAppear { load() }
    }

    private func card(_ candidate: MorningReviewPlanner.Candidate) -> some View {
        let source = spans.filter { $0.start < candidate.end && $0.end > candidate.start }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(candidate.start.formatted(date: .omitted, time: .shortened))–\(candidate.end.formatted(date: .omitted, time: .shortened)) · \(durationText(minutes: candidate.minutes))")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondaryText)
            HStack(alignment: .top, spacing: 16) {
                comparison("Screen saw", candidate.screen ?? "Unknown")
                comparison("You tracked", candidate.overlappingTracking ? "Overlapping labels" : candidate.tracked ?? "Untracked")
            }
            if let span = source.first {
                Text(span.title.isEmpty ? span.app : span.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(2)
                if !span.summary.isEmpty {
                    Text(span.summary).font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(3)
                }
            }
            if candidate.uncertain {
                Text("The screen label was uncertain.").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            ScreenEvidenceGallery(from: candidate.start, to: candidate.end, bundles: Set(source.map(\.bundleID)))
            VStack(spacing: 8) {
                Menu {
                    ForEach(settings.tags + ["Break"], id: \.self) { label in
                        Button(label) { correct(candidate, label: label) }
                    }
                } label: {
                    Text("Correct category").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canCorrect(candidate))
                .help("Change this saved stretch; your running timer is never changed")
                HStack(spacing: 8) {
                    Button { finish(candidate, disposition: "mixed", message: "Marked as mixed; time kept", undo: nil) } label: {
                        Text("Mixed").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .help("Keep the time as tracked and mark this stretch as mixed, without teaching a label")
                    Button { finish(candidate, disposition: "skip", message: "Skipped; time kept", undo: nil) } label: {
                        Text("Skip").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .help("Leave this stretch unchanged and move on")
                }
            }
            .font(.system(size: 13)).buttonStyle(.bordered).controlSize(.regular)
            if !canCorrect(candidate) {
                Text("This overlaps the running timer. You can mark it mixed or skip it.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func comparison(_ caption: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(settings.tags.contains(label) ? categoryColor(label) : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return }
        if preview {
            let start = yesterday.addingTimeInterval(14 * 3600)
            queue = [.init(start: start, end: start.addingTimeInterval(24 * 60), screen: "Math", tracked: "SWE",
                           uncertain: false, overlappingTracking: false)]
            spans = [ScreenSpan(start: start, end: start.addingTimeInterval(24 * 60), app: "Notes",
                                bundleID: "com.example.morning-review", title: "Discrete Math review",
                                summary: "Reviewing partial orders and chains.", category: "Math", active: true,
                                source: "model", reason: nil, uncertain: false)]
            startingCount = queue.count
            return
        }
        skipped = !preview && UserDefaults.standard.double(forKey: Self.skippedKey) == today.timeIntervalSince1970
        guard !skipped else { return }
        if let data = UserDefaults.standard.data(forKey: Self.receiptsKey),
           let saved = try? JSONDecoder().decode([Receipt].self, from: data) {
            receipts = saved.filter { $0.end > today.addingTimeInterval(-60 * 86400) }
        }
        spans = ScreenWatcher.shared.spans(from: yesterday, to: today).filter {
            $0.active != false && $0.source != "focus" && $0.bundleID != ScreenWatcher.ownBundle
                && !ScreenWatcher.privateApps.contains($0.bundleID)
        }
        let end = timer.isActive ? min(today, timer.sessionStartTime ?? today) : today
        let reviewed = receipts.map { DateInterval(start: $0.start, end: $0.end) }
            + ScreenWatcher.shared.checks.map { DateInterval(start: $0.start, end: $0.end) }
        let candidates = MorningReviewPlanner.candidates(
            observations: spans.map { .init(start: $0.start, end: $0.end, category: $0.category, uncertain: $0.uncertain == true) },
            tracking: store.sessions.map {
                .init(start: $0.startTime, end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
                      category: $0.type.isBreak ? "Break" : $0.label ?? "Focus")
            }, reviewed: reviewed, from: yesterday, to: end)
        queue = Array(candidates.prefix(3))
        startingCount = queue.count
    }

    private func canCorrect(_ candidate: MorningReviewPlanner.Candidate) -> Bool {
        preview || !timer.isActive || candidate.end <= (timer.sessionStartTime ?? Date())
    }

    private func correct(_ candidate: MorningReviewPlanner.Candidate, label: String) {
        guard canCorrect(candidate) else { return }
        if preview {
            finish(candidate, disposition: "corrected", message: "Changed to \(label)", undo: nil)
            return
        }
        guard let undo = store.paintForReview(start: candidate.start, end: candidate.end,
                                             label: label == "Break" ? nil : label) else {
            error = "Couldn't save that correction. Your review is still open."
            return
        }
        finish(candidate, disposition: "corrected", message: "Changed to \(label)", undo: undo)
    }

    private func finish(_ candidate: MorningReviewPlanner.Candidate, disposition: String,
                        message: String, undo: SessionStore.ReviewUndo?) {
        let receipt = Receipt(id: UUID(), start: candidate.start, end: candidate.end, disposition: disposition)
        receipts.append(receipt)
        persistReceipts()
        changes.append(Change(candidate: candidate, receiptID: receipt.id, undo: undo, message: message))
        queue.removeAll { $0.id == candidate.id }
        reviewedCount += 1
        error = nil
    }

    private func undoLast() {
        guard let change = changes.last else { return }
        if let undo = change.undo, !store.undoReview(undo) {
            error = "That time changed since your correction. Undo is unavailable; review it in the Dashboard."
            return
        }
        receipts.removeAll { $0.id == change.receiptID }
        persistReceipts()
        queue.insert(change.candidate, at: 0)
        changes.removeLast()
        reviewedCount -= 1
        error = nil
    }

    private func persistReceipts() {
        guard !preview, let data = try? JSONEncoder().encode(receipts) else { return }
        UserDefaults.standard.set(data, forKey: Self.receiptsKey)
    }

    private func skipToday() {
        skipped = true
        if !preview {
            UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: Self.skippedKey)
        }
    }
}
