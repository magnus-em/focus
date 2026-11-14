import AppKit
import Charts
import SwiftUI

// MARK: - Window controller

@MainActor
final class ZetamacWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    /// True if the Math Sprint window was open at the previous quit. Used
    /// at app launch to auto-restore the window. (An in-flight game itself
    /// is in-memory only and resets on quit.)
    static var wasOpenAtQuit: Bool {
        UserDefaults.standard.bool(forKey: "zetamac.windowOpen")
    }

    func open(store: ZetamacStore) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ZetamacView(store: store)
        let vc = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: vc)
        w.title = "Math Sprint"
        w.setContentSize(NSSize(width: 600, height: 720))
        w.minSize = NSSize(width: 480, height: 600)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        UserDefaults.standard.set(true, forKey: "zetamac.windowOpen")
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "zetamac.windowOpen")
    }
}

// MARK: - Game model

private enum MathOp: CaseIterable { case add, sub, mul, div }

private struct MathProblem: Equatable {
    let prompt: String
    let answer: Int
}

private func makeProblem() -> MathProblem {
    switch MathOp.allCases.randomElement()! {
    case .add:
        let a = Int.random(in: 2...100), b = Int.random(in: 2...100)
        let (l, r) = Bool.random() ? (a, b) : (b, a)
        return MathProblem(prompt: "\(l) + \(r)", answer: a + b)
    case .sub:
        let a = Int.random(in: 2...100), b = Int.random(in: 2...100)
        let sum = a + b
        return Bool.random()
            ? MathProblem(prompt: "\(sum) − \(a)", answer: b)
            : MathProblem(prompt: "\(sum) − \(b)", answer: a)
    case .mul:
        let a = Int.random(in: 2...12), b = Int.random(in: 2...100)
        let (l, r) = Bool.random() ? (a, b) : (b, a)
        return MathProblem(prompt: "\(l) × \(r)", answer: a * b)
    case .div:
        let a = Int.random(in: 2...12), b = Int.random(in: 2...100)
        return MathProblem(prompt: "\(a * b) ÷ \(a)", answer: b)
    }
}

// MARK: - Trend helpers

private struct DailyBest: Identifiable {
    var id: Date { day }
    let day: Date
    let best: Int
    let games: Int
}

/// Daily best score for each of the last `days` days, including empty days
/// (best = 0). Returning the full window — gaps and all — keeps the bar
/// chart's x-axis evenly spaced instead of bunching points by date density.
private func dailyBests(_ results: [ZetamacGameResult], days: Int) -> [DailyBest] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    var byDay: [Date: (best: Int, count: Int)] = [:]
    for r in results {
        let d = cal.startOfDay(for: r.startTime)
        let prior = byDay[d] ?? (0, 0)
        byDay[d] = (max(prior.best, r.correctCount), prior.count + 1)
    }
    var out: [DailyBest] = []
    out.reserveCapacity(days)
    for offset in stride(from: days - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
        let agg = byDay[d] ?? (0, 0)
        out.append(DailyBest(day: d, best: agg.best, games: agg.count))
    }
    return out
}

// MARK: - Phase

private enum GamePhase: Equatable {
    case idle
    case running
    case finished(score: Int, attempted: Int)
}

// MARK: - View

struct ZetamacView: View {
    @ObservedObject var store: ZetamacStore

    private let durationSeconds: Int = 120

    @State private var phase: GamePhase = .idle
    @State private var endTime: Date = .distantPast
    @State private var startTime: Date = .distantPast
    @State private var secondsLeft: Int = 120
    @State private var currentProblem: MathProblem = makeProblem()
    @State private var input: String = ""
    @State private var correct: Int = 0
    @State private var attempted: Int = 0
    @FocusState private var inputFocused: Bool

    private let blue  = Color(red: 0.27, green: 0.62, blue: 0.83)
    private let green = Color(red: 0.25, green: 0.72, blue: 0.53)
    private let amber = Color(red: 0.98, green: 0.70, blue: 0.18)

    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch phase {
                case .idle:      idleScreen
                case .running:   gameScreen
                case .finished(let s, let a): finishedScreen(score: s, attempted: a)
                }
            }
            .padding(20)

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                goalBanner
                history
                dailyBestChart
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(minWidth: 480, minHeight: 600)
        .onReceive(tick) { _ in
            guard case .running = phase else { return }
            let remaining = max(0, Int(endTime.timeIntervalSinceNow.rounded(.up)))
            if remaining != secondsLeft { secondsLeft = remaining }
            store.gameTick(score: correct, secondsLeft: remaining)
            if remaining == 0 { finishGame() }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Math Sprint")
                    .font(.system(size: 20, weight: .semibold))
                Text("Zetamac-style mental arithmetic · 120 s")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statChip(label: "Best", value: "\(store.bestScore)")
            statChip(label: "Today", value: "\(store.todayBest)")
            statChip(label: "7-day avg", value: String(format: "%.0f", store.recentAverage(days: 7)))
        }
    }

    private func statChip(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    // MARK: idle

    private var idleScreen: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(blue)
            Text("120 seconds. Mixed +, −, ×, ÷.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Just type the answer — no Enter needed.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Button {
                startGame()
            } label: {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(blue))
            }
            .buttonStyle(.plainHit)
            .keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: running game

    private var gameScreen: some View {
        VStack(spacing: 22) {
            HStack {
                Label("\(secondsLeft)s", systemImage: "timer")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(secondsLeft <= 10 ? Color.red : .primary)
                Spacer()
                Text("Score: \(correct)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(green)
            }

            Spacer(minLength: 0)

            Text(currentProblem.prompt)
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()

            TextField("", text: $input)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 36, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 220, height: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(blue.opacity(0.3), lineWidth: 1))
                .focused($inputFocused)
                .onChange(of: input) { _, newValue in
                    handleInputChange(newValue)
                }

            Spacer(minLength: 0)

            Button("Stop") { finishGame() }
                .buttonStyle(.plainHit)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: finished

    private func finishedScreen(score: Int, attempted: Int) -> some View {
        let isPB = score > 0 && score >= store.bestScore
        return VStack(spacing: 16) {
            Spacer(minLength: 8)
            Text("Time!")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("\(score)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(green)

            HStack(spacing: 24) {
                metric(label: "Per min", value: String(format: "%.1f", Double(score) * 60.0 / Double(durationSeconds)))
                metric(label: "Today best", value: "\(store.todayBest)")
                metric(label: "All-time best", value: "\(store.bestScore)")
            }

            if isPB {
                Text("New personal best")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(amber)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(amber.opacity(0.15)))
            }

            HStack(spacing: 10) {
                Button {
                    startGame()
                } label: {
                    Text("Play again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 130, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(blue))
                }
                .buttonStyle(.plainHit)
                .keyboardShortcut(.defaultAction)

                Button {
                    phase = .idle
                } label: {
                    Text("Close")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.1)))
                }
                .buttonStyle(.plainHit)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    // MARK: history strip

    private var history: some View {
        let recent = Array(store.results.prefix(10))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recent games")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            if recent.isEmpty {
                Text("No games yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    let maxScore = max(recent.map(\.correctCount).max() ?? 1, 1)
                    ForEach(recent.reversed()) { r in
                        VStack(spacing: 4) {
                            Text("\(r.correctCount)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(blue.opacity(0.7))
                                .frame(height: max(6, CGFloat(r.correctCount) / CGFloat(maxScore) * 48))
                            Text(shortDay(r.startTime))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 80)
            }
        }
    }

    // MARK: goal banner

    private var goalBanner: some View {
        let n = store.todaySessionCount
        let hasPB = store.todayHasPersonalBest
        let met = store.todayGoalMet
        let floor = ZetamacStore.dailyGoalFloor
        let ceiling = ZetamacStore.dailyGoalCeiling
        let priorBest = store.bestBeforeToday

        let icon: String
        let tint: Color
        let title: String
        let subtitle: String

        if met {
            icon = "checkmark.seal.fill"
            tint = green
            if hasPB {
                title = "Daily goal complete · new PB"
                subtitle = "\(n) game\(n == 1 ? "" : "s") today · keep playing or stop here"
            } else {
                title = "Daily goal complete"
                subtitle = "\(n) games today · keep playing or stop here"
            }
        } else if n < floor {
            icon = "target"
            tint = .secondary
            title = "Daily goal · \(n)/\(floor)"
            subtitle = "play \(floor - n) more to unlock the PB stop"
        } else {
            icon = "target"
            tint = amber
            title = "Daily goal · \(n)/\(ceiling)"
            subtitle = priorBest > 0
                ? "beat \(priorBest) for a PB, or play to \(ceiling)"
                : "set a PB, or play to \(ceiling)"
        }

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            goalDots(count: n, met: met)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(met ? green.opacity(0.10) : Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(met ? green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func goalDots(count: Int, met: Bool) -> some View {
        let ceiling = ZetamacStore.dailyGoalCeiling
        let floor = ZetamacStore.dailyGoalFloor
        return HStack(spacing: 3) {
            ForEach(0..<ceiling, id: \.self) { i in
                let filled = i < min(count, ceiling)
                let isFloorMark = i == floor - 1
                Circle()
                    .fill(filled ? (met ? green : blue) : Color.gray.opacity(0.18))
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(isFloorMark && !filled ? amber.opacity(0.7) : Color.clear, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: daily-best chart

    private var dailyBestChart: some View {
        let windowDays = 30
        let series = dailyBests(store.results, days: windowDays)
        let totalGames = store.results.count
        let goal = 80
        let dataMax = series.map(\.best).max() ?? 0
        let yMax = max(Int(Double(max(dataMax, goal)) * 1.1), 20)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daily best · last \(windowDays) days")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(totalGames) game\(totalGames == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if totalGames == 0 {
                Text("Play your first game to see daily bests.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 120)
            } else {
                Chart {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(amber.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .topTrailing, alignment: .trailing) {
                            Text("goal \(goal)")
                                .font(.system(size: 9))
                                .foregroundStyle(amber)
                        }
                    ForEach(series) { d in
                        BarMark(
                            x: .value("Day", d.day, unit: .day),
                            y: .value("Best", d.best),
                            width: .ratio(0.65)
                        )
                        .foregroundStyle(
                            cal.isDate(d.day, inSameDayAs: today)
                                ? green.gradient
                                : blue.opacity(0.75).gradient
                        )
                        .cornerRadius(2)
                    }
                }
                .chartYScale(domain: 0...yMax)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, windowDays / 6))) { value in
                        AxisGridLine().foregroundStyle(Color.gray.opacity(0.08))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 130)
            }
        }
    }

    private func shortDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: d)
    }

    // MARK: game flow

    private func startGame() {
        correct = 0
        attempted = 0
        input = ""
        currentProblem = makeProblem()
        startTime = Date()
        endTime = startTime.addingTimeInterval(TimeInterval(durationSeconds))
        secondsLeft = durationSeconds
        phase = .running
        store.gameStarted(durationSeconds: durationSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            inputFocused = true
        }
    }

    private func handleInputChange(_ newValue: String) {
        let filtered = newValue.filter { $0.isNumber }
        if filtered != newValue {
            input = filtered
            return
        }
        guard !filtered.isEmpty, let typed = Int(filtered) else { return }

        if typed == currentProblem.answer {
            correct += 1
            attempted += 1
            input = ""
            currentProblem = makeProblem()
        }
    }

    private func finishGame() {
        guard case .running = phase else { return }
        let result = ZetamacGameResult(
            startTime: startTime,
            durationSeconds: durationSeconds,
            correctCount: correct,
            attemptedCount: attempted
        )
        store.record(result)
        store.gameFinished()
        phase = .finished(score: correct, attempted: attempted)
        inputFocused = false
    }
}
