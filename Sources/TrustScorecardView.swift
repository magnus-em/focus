import SwiftUI
import Combine
import FocusCore

struct TrustScorecardView: View {
    let watcher: ScreenWatcher
    let day: Date
    let sessions: [WorkSession]
    var preview = false
    @State private var mode: TrustScorecard.Mode = .normal
    @State private var cards: [TrustScorecard.Card] = []
    @State private var cached = TrustScorecard.Score()

    private var from: Date { Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: day))! }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))! }

    private var score: TrustScorecard.Score {
        if preview {
            var score = TrustScorecard.Score()
            score.checked = 8; score.right = 6; score.comparedSeconds = 7200; score.agreeingSeconds = 6300
            score.switched = 3; score.kept = 2; score.ignored = 1; score.automatic = 4; score.undone = 1
            score.delays = [45, 60, 120]
            return score
        }
        let checks = watcher.checks.filter { $0.end > from && $0.start < end && $0.disposition == nil }
            .map { TrustScorecard.Check(right: $0.right, mode: $0.testMode.map { $0 ? .test : .normal } ?? .unknown) }
        let observations = watcher.spans(from: from, to: end)
            .filter { $0.active != false && $0.source != "focus" && $0.bundleID != ScreenWatcher.ownBundle
                && !ScreenWatcher.privateApps.contains($0.bundleID) }
            .map { TrustScorecard.Observation(start: $0.start, end: $0.end, category: $0.category,
                                              mode: $0.testMode.map { $0 ? .test : .normal } ?? .unknown) }
        return TrustScorecard.score(mode: mode, observations: observations, tracking: sessions,
                                     checks: checks, cards: cards, from: from, to: end, now: Date())
    }

    var body: some View {
        let score = cached
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Can you trust the labels?").font(.system(size: 15, weight: .semibold))
                Text("Last 7 days ending \(day.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            Picker("Data mode", selection: $mode) {
                Text("Normal").tag(TrustScorecard.Mode.normal)
                Text("Test mode").tag(TrustScorecard.Mode.test)
                Text("Earlier data").tag(TrustScorecard.Mode.unknown)
            }
            .pickerStyle(.segmented)
            if mode == .unknown {
                Text("These records predate mode tracking. They aren't counted as normal or test results.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
                metric("Checked accuracy", score.checked > 0 ? percent(score.right, score.checked) : "No checks yet",
                       "\(score.right) right / \(score.checked) checked stretches")
                metric("Tracking agreement", score.comparedSeconds > 0 ? percent(score.agreeingSeconds, score.comparedSeconds) : "No overlap yet",
                       "\(Int(score.comparedSeconds / 60)) comparable minutes")
                metric("Cards you answered", "\(score.switched) switched · \(score.kept) kept",
                       "\(score.dismissed) dismissed · \(score.ignored) unanswered · \(score.pending) pending")
                metric("Automatic switches undone", score.automatic > 0 ? percent(score.undone, score.automatic) : "No auto-switches",
                       "\(score.undone) undone / \(score.automatic) completed")
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Typical detection delay").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(score.medianDelay.map { "\(Int($0.rounded())) sec · \(score.delays.count) cards" } ?? "Not measured yet")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            Text("Checks reflect stretches you chose to review. Agreement compares labels with your timer, not verified accuracy. Delay runs from the first supporting screen sample to the card; it doesn't measure when your real task changed. Unanswered cards aren't wrong labels.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .onAppear { reload() }
        .onChange(of: day) { _, _ in reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    private func reload() {
        if !preview { cards = PromptLog.scorecardCards(since: from) }
        cached = score
    }

    private func percent<T: BinaryInteger>(_ a: T, _ b: T) -> String { percent(Double(a), Double(b)) }
    private func percent(_ a: Double, _ b: Double) -> String { "\(Int((100 * a / b).rounded()))%" }

    private func metric(_ caption: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Text(value).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
