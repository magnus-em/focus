import SwiftUI
import AppKit
import Carbon.HIToolbox
import Charts
import FocusCore

/// The Insights window (⌃⌥⌘G, `focus://insights`): your goals and where the
/// week's effort went, the written analysis, and when attention left the work.
@MainActor
final class InsightsWindowController: NSObject, NSWindowDelegate {
    static let shared = InsightsWindowController()
    private var window: NSWindow?
    private var hotKey: GlobalHotKey?

    func registerHotKey() {
        guard hotKey == nil else { return }
        let mods = GlobalHotKey.controlModifier | GlobalHotKey.optionModifier | GlobalHotKey.commandModifier
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: mods) { [weak self] in
            Task { @MainActor in self?.open() }
        }
    }

    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: InsightsView()))
        w.title = "Insights"
        w.setContentSize(NSSize(width: 1040, height: 820))
        w.minSize = NSSize(width: 820, height: 600)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private func hm(_ minutes: Double) -> String {
    let m = Int(minutes.rounded())
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

struct InsightsView: View {
    var body: some View {
        ScrollView {
            InsightsContent(embedded: false)
                .padding(32)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The page itself: in its own window, or as the Dashboard's Insights page
/// (`embedded`, where the Dashboard's toolbar carries the title).
struct InsightsContent: View {
    var embedded = false
    @ObservedObject private var store = InsightsStore.shared
    @ObservedObject private var goals = GoalsStore.shared
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if let s = store.summary {
                hero(s)
                goalsSection(s)
                attentionSection(s).id("insights-attention")
                if let u = store.aiUse { aiSection(u).id("insights-ai") }
                reportSection.id("insights-report")
                timerSection(s)
                accuracySection.id("insights-accuracy")
                daysSection(s).id("insights-days")
                studySection(s)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onAppear { store.appeared() }
        .onDisappear { store.disappeared() }
        .sheet(isPresented: $editing) { GoalsEditor(initial: goals.doc.goals) { goals.save($0) } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if embedded {
                Text("Ranked by your goals, from your timer and what the screen saw")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights").font(.system(size: 26, weight: .semibold))
                    Text("Where your effort went, ranked by your goals, from your timer and what the screen saw")
                        .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                }
            }
            Spacer()
            Picker("", selection: $store.days) {
                Text("7 days").tag(7)
                Text("28 days").tag(28)
            }
            .pickerStyle(.segmented).frame(width: 160).labelsHidden()
        }
    }

    // MARK: Hero

    private func hero(_ s: Insights.Summary) -> some View {
        let avoided = goals.avoided.map(\.title)
        let total = s.avoidedMinutes + s.otherGoalMinutes + s.noGoalMinutes
        let a = s.attention
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pct(s.avoidedShare)).font(.system(size: 46, weight: .semibold)).monospacedDigit()
                Text("of your focus went to \(avoided.isEmpty ? "the goals you put off" : avoided.joined(separator: " and "))")
                    .font(.system(size: 15, weight: .medium))
                Text("\(hm(s.avoidedMinutes)) of \(hm(total)) of focus work the screen saw. First block of the day went there on \(s.avoidedFirstDays) of \(s.days.filter { $0.firstFocus != nil }.count) days.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(a.longestStretchMinutes > 0 ? hm(a.longestStretchMinutes) : "–")
                    .font(.system(size: 46, weight: .semibold)).monospacedDigit()
                Text("your longest study without a distraction").font(.system(size: 15, weight: .medium))
                Text(a.longestStretchMinutes > 0
                     ? "Half your study time came in stretches of \(hm(a.halfTimeMinutes)) or more. \(a.distractors.first.map { "\($0.name) ended the most (\($0.count)×)." } ?? "")"
                     : "Nothing yet in focus blocks the Mac saw.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Goals

    private func goalsSection(_ s: Insights.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Your goals", subtitle: "In your order. Time is what the screen showed you doing for each; the timer's count is beside it")
                Spacer()
                if let r = goals.doc.reviewedAt { Text("Reviewed \(r.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                Button("Edit goals") { editing = true }
            }
            ForEach(s.goals) { g in GoalRow(goal: g, days: s.days.map(\.date)) }
        }
    }

    // MARK: Written analysis

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let r = store.latest {
                    SectionTitle("This week, in words",
                                 subtitle: "Written by \(r.author == "Focus" ? r.model : r.author) on \(r.writtenAt.formatted(date: .abbreviated, time: .shortened)) from these numbers")
                } else {
                    SectionTitle("This week, in words", subtitle: "A strong model reads the numbers below and your goals, every Sunday evening and when you change your goals")
                }
                Spacer()
                if !store.writeStatus.isEmpty { Text(store.writeStatus).font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                Button(store.writing ? "Writing…" : "Rewrite now") { Task { await store.write(reason: "asked") } }
                    .disabled(store.writing || InsightsWriter.available == nil)
                    .help(InsightsWriter.available.map { "Writes with \($0)" } ?? "Add an Anthropic key or turn on Cloud AI first")
            }
            if let r = store.latest { ReportView(report: r.content).frame(maxWidth: 820, alignment: .leading) }
            else {
                Text(InsightsWriter.available == nil
                     ? "No model to write with yet. Add an Anthropic key in Settings → Recall, or turn on Cloud AI, or ask Claude Code to write it."
                     : "Nothing written yet.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    // MARK: Timer vs screen

    private func timerSection(_ s: Insights.Summary) -> some View {
        let parts: [(String, Double, Color)] = [
            ("Focus work on screen", s.confirmedMinutes, .green),
            ("Something else on screen", s.offTaskMinutes, .orange),
            ("Nothing on screen", s.unseenMinutes, Color.gray.opacity(0.45)),
        ]
        let total = max(1, s.trackedFocusMinutes)
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Your timer against the screen",
                         subtitle: "\(hm(s.trackedFocusMinutes)) on the focus timer. Nothing on screen can be paper, the iPad, a lecture or a timer left running")
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        RoundedRectangle(cornerRadius: 4).fill(p.2).frame(width: max(0, geo.size.width * p.1 / total - 2))
                    }
                }
            }.frame(height: 14)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(hm(p.1))").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: Reading accuracy

    /// The bar in CATEGORIES.md for letting Focus name every block.
    private var accuracySection: some View {
        let days = store.accuracy.filter { $0.readSeconds >= 60 || $0.autoSwitches > 0 || $0.corrections > 0 }
        let t = ReadingAccuracy.total(days)
        let anyCorrections = days.contains { $0.corrections > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle("How well Focus reads your screen",
                         subtitle: "Last \(store.days) days of focus blocks: how often what Focus saw on your screen matched the category on your timer")
            HStack(alignment: .top, spacing: 28) {
                measure(t.right.map(pct) ?? "–", "matched your timer", goal: 0.9, value: t.right, higherIsBetter: true, bar: "goal 90%")
                measure(t.unlabeled.map(pct) ?? "–", "couldn't tell what it was", goal: 0.05, value: t.unlabeled, higherIsBetter: false,
                        bar: "goal 5% or less")
                measure(t.autoSwitches > 0 ? "\(t.undone) of \(t.autoSwitches)" : "–", "automatic switches you undid",
                        goal: 0.1, value: t.undoneShare, higherIsBetter: false, bar: "goal 1 in 10")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(t.corrections)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text(t.corrections == 1 ? "time you corrected it" : "times you corrected it")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    if t.courseCorrections > 0 {
                        Text("\(t.courseCorrections) named a class").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            if !days.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("Day").gridColumnAlignment(.leading)
                        Text("Matched")
                        Text("Couldn't tell")
                        Text("Switches undone")
                        if anyCorrections { Text("Corrections") }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondaryText)
                    ForEach(days.reversed()) { d in
                        GridRow {
                            Text(Calendar.current.isDateInToday(d.day) ? "Today (so far)"
                                 : d.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            cell(d.right.map(pct), met: d.right.map { $0 >= ReadingAccuracy.rightBar })
                            cell(d.unlabeled.map(pct), met: d.unlabeled.map { $0 <= ReadingAccuracy.unlabeledBar })
                            cell(d.autoSwitches > 0 ? "\(d.undone) of \(d.autoSwitches)" : nil,
                                 met: d.undoneShare.map { $0 <= ReadingAccuracy.undoneBar })
                            if anyCorrections { cell(d.corrections > 0 ? "\(d.corrections)" : nil, met: nil) }
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            Text("Matched: focus time where Focus's reading of the screen was the same category as your timer. Time on a window before you corrected it counts as not matching, and so does a trip to Messages or a feed. ✓ marks a day that met the goal. To correct a reading, click the button under the timer in the menu bar that names what Focus read (\u{201C}Not SWE?\u{201D}), or press ⌃⌥⌘ and the ' key.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func measure(_ text: String, _ label: String, goal: Double, value: Double?, higherIsBetter: Bool, bar: String) -> some View {
        let met = value.map { higherIsBetter ? $0 >= goal : $0 <= goal }
        let gap = value.map { Int((abs($0 - goal) * 100).rounded()) }
        let status: String = {
            guard let met, let gap else { return bar }
            if met { return bar + " · met" }
            if text.contains(" of "), let v = value, v > 0 { return bar + " · you undid 1 in \(Int((1 / v).rounded()))" }
            return bar + " · \(gap) point\(gap == 1 ? "" : "s") \(higherIsBetter ? "short" : "over")"
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(met == true ? Color.good : Color.primary)
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Label(status, systemImage: met == true ? "checkmark.circle.fill" : "flag")
                .font(.system(size: 11)).foregroundStyle(met == true ? Color.good : Color.secondaryText)
        }
    }

    private func cell(_ value: String?, met: Bool?) -> some View {
        HStack(spacing: 4) {
            if met == true { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.good) }
            Text(value ?? "–").monospacedDigit()
                .foregroundStyle(value == nil ? Color.secondaryText : (met == true ? Color.good : Color.primary))
        }
    }

    // MARK: Attention

    private func attentionSection(_ s: Insights.Summary) -> some View {
        let a = s.attention
        let studyDays = s.days.filter { $0.longestStretch != nil || $0.trackedFocus > 0 }
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle("How long you stay focused",
                         subtitle: "Stretches of study with nothing else in front. AI chats about the work count as study; Messages, feeds, email and side projects end a stretch after 5 seconds")
            HStack(alignment: .top, spacing: 28) {
                stat(hm(a.longestStretchMinutes), "longest stretch")
                stat(hm(a.halfTimeMinutes) + "+", "half your study came in stretches this long")
                stat("\(a.stretches25)", a.stretches25 == 1 ? "stretch of 25+ min" : "stretches of 25+ min")
                stat(String(format: "%.1f", a.perFocusHour), "distractions an hour")
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Longest stretch each day").font(.system(size: 13, weight: .semibold))
                    Chart {
                        ForEach(studyDays) { d in
                            BarMark(x: .value("Day", d.date, unit: .day), y: .value("Minutes", d.longestStretch ?? 0))
                                .foregroundStyle(Color.accentColor.opacity(0.8))
                                .annotation(position: .top) {
                                    if let m = d.longestStretch {
                                        Text("\(Int(m.rounded()))").font(.system(size: 10)).foregroundStyle(Color.secondaryText)
                                    }
                                }
                        }
                        RuleMark(y: .value("25 min", 25))
                            .foregroundStyle(Color.green.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("25 min").font(.system(size: 10)).foregroundStyle(.green)
                            }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .frame(height: 150)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("What ended your stretches").font(.system(size: 13, weight: .semibold))
                    ForEach(a.distractors.prefix(7)) { d in
                        HStack(alignment: .firstTextBaseline) {
                            Text(d.name).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(d.count)× · \(hm(d.minutes)) away").font(.system(size: 12)).foregroundStyle(Color.secondaryText).monospacedDigit()
                        }
                        .help("Ended stretches that had reached \(hm(d.averageEnded)) on average")
                    }
                    if a.distractors.isEmpty { Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                }
                .frame(width: 320)
            }
            Text(attentionFootnote(a)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attentionFootnote(_ a: Insights.Attention) -> String {
        guard a.focusHoursSeen >= 0.1 else { return "No focus blocks the Mac saw yet." }
        var t = "From \(String(format: "%.1f", a.focusHoursSeen)) h of focus blocks the Mac saw: \(a.distractions) distractions, \(hm(a.distractionMinutes)) away in all."
        if a.fineShare < 0.95 {
            t += " Days before Nov 10 come from 15-second screen readings, which miss short trips away, so their stretches look longer than they were."
        }
        return t
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: AI

    private func aiSection(_ u: AIUsage.Summary) -> some View {
        let now = u.perDay
        let before = store.aiBefore.flatMap { $0.activeDays > 0 ? $0 : nil }
        let was = before?.perDay
        let since = before.map { "vs " + range($0.period) }
        let shown = u.categories.filter { $0.share != nil && $0.trackedSeconds >= 30 * 60 }
        let cats = (shown.filter(\.isFocus).sorted { $0.share! > $1.share! } + shown.filter { !$0.isFocus }.sorted { $0.share! > $1.share! })
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 16) {
            SectionTitle("How much you use AI",
                         subtitle: "ChatGPT, Codex, Claude and Gemini on this Mac, \(range(u.period)), as averages per day")
            HStack(alignment: .top, spacing: 24) {
                aiStat(hm(now.aiSeconds / 60), "a day with AI on screen, \(pct(u.share)) of your time at the Mac",
                       change: was.map { minutesChange(now.aiSeconds - $0.aiSeconds) }, since: since)
                aiStat(Int(now.wrote.rounded()).formatted(), "words a day you wrote to AI",
                       change: was.map { wordsChange(now.wrote - $0.wrote) }, since: since)
                aiStat(Int(now.read.rounded()).formatted(), "words a day AI wrote back",
                       change: was.map { wordsChange(now.read - $0.read) }, since: since)
                aiStat(hm(now.workSeconds / 60), "a day AI was working for you, often in the background",
                       change: was.map { minutesChange(now.workSeconds - $0.workSeconds) }, since: since)
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI on screen each day").font(.system(size: 13, weight: .semibold))
                    Chart {
                        ForEach(u.days) { d in
                            BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", d.aiSeconds / 3600))
                                .foregroundStyle(Color.primary.opacity(0.45))
                                .annotation(position: .top) {
                                    if d.macSeconds >= 600 {
                                        Text(pct(d.share)).font(.system(size: 11)).foregroundStyle(Color.secondaryText).monospacedDigit()
                                    }
                                }
                        }
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(h.formatted(.number.precision(.fractionLength(0...1)))) h") } } } }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: u.days.count > 7 ? 7 : 1)) { v in
                            AxisValueLabel(centered: true) {
                                if let d = v.as(Date.self) {
                                    Text(cal.isDateInToday(d) ? "Today" : d.formatted(u.days.count > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated).day()))
                                }
                            }
                        }
                    }
                    .frame(height: 210)
                    Text("Above each bar: its share of that day's time at the Mac").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where you use it").font(.system(size: 13, weight: .semibold))
                    Text("Share of each category's timer blocks with AI on screen").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    ForEach(cats.prefix(9)) { c in
                        HStack(spacing: 10) {
                            Text(c.name).font(.system(size: 13)).lineLimit(1).frame(width: 90, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.1))
                                    Capsule().fill(categoryColor(c.name)).frame(width: max(3, g.size.width * (c.share ?? 0)))
                                }
                            }
                            .frame(height: 6)
                            Text(pct(c.share ?? 0)).font(.system(size: 13)).monospacedDigit().frame(width: 38, alignment: .trailing)
                            Text("of \(String(format: "%.1f", c.trackedSeconds / 3600)) h").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                                .monospacedDigit().frame(width: 58, alignment: .trailing)
                        }
                        .help("\(hm(c.aiSeconds / 60)) with AI on screen in \(hm(c.trackedSeconds / 60)) of \(c.name) on the timer; \(c.messages) \(c.messages == 1 ? "message" : "messages") to AI")
                    }
                    if cats.isEmpty { Text("No timer blocks at the Mac yet").font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                }
                .frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Each tool, \(range(u.period)) in all").font(.system(size: 13, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                    GridRow {
                        Text("Tool")
                        Text("On screen").gridColumnAlignment(.trailing)
                        Text("You wrote").gridColumnAlignment(.trailing)
                        Text("It wrote back").gridColumnAlignment(.trailing)
                        Text("Working for you").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondaryText)
                    ForEach(u.tools) { t in
                        let recorded = t.provider == .openAI || t.provider == .anthropic
                        GridRow {
                            Text(t.provider.rawValue)
                            Text(hm(t.aiSeconds / 60))
                            Text(recorded ? "\(t.wrote.formatted()) words" : "not recorded")
                            Text(recorded ? "\(t.read.formatted()) words\(t.provider == .anthropic ? " †" : "")" : "not recorded")
                            Text(recorded ? hm(t.workSeconds / 60) : "not recorded")
                        }
                        .font(.system(size: 13)).monospacedDigit()
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("All tools")
                        Text(hm(u.aiSeconds / 60))
                        Text("\(u.wrote.formatted()) words")
                        Text("\(u.read.formatted()) words")
                        Text(hm(u.workSeconds / 60))
                    }
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
            Text(aiFootnote(u)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func aiStat(_ value: String, _ label: String, change: String?, since: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let change, let since {
                Text("\(change) \(since)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(change.hasPrefix("+") ? Color.green : Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func minutesChange(_ seconds: Double) -> String {
        let m = (seconds / 60).rounded()
        return m == 0 ? "Same" : (m > 0 ? "+" : "−") + hm(abs(m))
    }

    private func wordsChange(_ words: Double) -> String {
        let w = Int(words.rounded())
        return w == 0 ? "Same" : (w > 0 ? "+" : "−") + abs(w).formatted()
    }

    private func range(_ p: DateInterval) -> String {
        let last = p.end.addingTimeInterval(-1)
        let cal = Calendar.current
        if cal.isDate(p.start, equalTo: last, toGranularity: .month) {
            return "\(p.start.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.day()))"
        }
        return "\(p.start.formatted(.dateTime.month(.abbreviated).day()))–\(last.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func aiFootnote(_ u: AIUsage.Summary) -> String {
        var t = "\(u.messages.formatted()) messages from you in all. Words back are replies in Claude Code and the ChatGPT app (its chats and Codex). † Claude chats outside Claude Code count only what you wrote; their replies aren't on this Mac."
        t += " Working for you is time Claude Code or the ChatGPT app spent answering, thinking or running tools; tools working at the same time count once in All tools."
        if let windowLog = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10)), u.period.start < windowLog {
            t += " Before Nov 10, time on screen comes from 15-second screen readings, which miss AI websites in Chrome."
        }
        return t
    }

    // MARK: Days

    private func daysSection(_ s: Insights.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Day by day", subtitle: "When the put-off work started, and how long you stayed focused")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Day", "Timer focus", "On screen", "Put-off goals", "First focus", "First put-off work", "Longest stretch", "Distractions / h", "AI msgs"], id: \.self) {
                        Text($0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondaryText)
                    }
                }
                ForEach(s.days.reversed()) { d in
                    GridRow {
                        Text(d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        Text(hm(d.trackedFocus)).monospacedDigit()
                        Text(hm(d.confirmedStudy)).monospacedDigit()
                        Text(d.avoidedMinutes > 0 ? hm(d.avoidedMinutes) : "none").monospacedDigit()
                            .foregroundStyle(d.avoidedMinutes > 0 ? Color.primary : Color.orange)
                        Text(d.firstFocus.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                        Text(d.firstAvoided.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                        Text(d.longestStretch.map { hm($0) } ?? "–").monospacedDigit()
                        Text(d.distractionsPerHour.map { String(format: "%.1f", $0) } ?? "–").monospacedDigit()
                        Text(d.aiMessages > 0 ? "\(d.aiMessages)" : "–").monospacedDigit()
                    }.font(.system(size: 13))
                }
            }
        }
    }

    // MARK: Study

    private func studySection(_ s: Insights.Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("How you studied", subtitle: "From the cloud readings of study screens, and what you typed to AI tools")
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Doing what").font(.system(size: 13, weight: .semibold))
                    let total = max(1, s.activityMinutes.values.reduce(0, +))
                    ForEach(s.activityMinutes.sorted { $0.value > $1.value }.prefix(6), id: \.key) { k, v in
                        HStack { Text(k == "asking-ai" ? "Asking AI" : k.replacingOccurrences(of: "-", with: " ").capitalized); Spacer(); Text(pct(v / total)).monospacedDigit() }
                            .font(.system(size: 13))
                    }
                }.frame(width: 220)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Courses on screen").font(.system(size: 13, weight: .semibold))
                    ForEach(s.courseMinutes.sorted { $0.value > $1.value }.prefix(6), id: \.key) { k, v in
                        HStack { Text(k); Spacer(); Text(hm(v)).monospacedDigit() }.font(.system(size: 13))
                    }
                }.frame(width: 240)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Came up again and again").font(.system(size: 13, weight: .semibold))
                    ForEach(s.repeatedConcepts.prefix(8), id: \.concept) { c in
                        HStack { Text(c.concept).lineLimit(1); Spacer(); Text("\(c.days) days").monospacedDigit() }.font(.system(size: 13))
                    }
                    if s.repeatedConcepts.isEmpty { Text("Nothing on 3+ days").font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                }
            }
            Text("\(s.aiMessages) messages typed to AI tools" + (s.aiByTool.isEmpty ? "" : " (" + s.aiByTool.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")") + "; \(s.questions) study questions seen on screen.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
    }
}

private struct GoalRow: View {
    let goal: Insights.GoalProgress
    let days: [Date]

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(goal.rank). \(goal.title)").font(.system(size: 14, weight: .semibold))
                    if goal.avoided {
                        Text("put off").font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18))).foregroundStyle(.orange)
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                let target = goal.target ?? 0
                if target > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.gray.opacity(0.18))
                            Capsule().fill(goal.screenMinutes >= target ? Color.good : goal.avoided ? Color.orange : Color.accentColor)
                                .frame(width: max(6, geo.size.width * min(1, goal.screenMinutes / target)))
                        }
                    }
                    .frame(height: 6)
                }
                Text(target > 0 ? "\(hm(goal.screenMinutes)) of \(hm(target)) on screen" : "\(hm(goal.screenMinutes)) on screen · no target")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text("\(hm(goal.trackedMinutes)) on the timer").font(.system(size: 12)).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
            .frame(width: 260, alignment: .leading)
            HStack(alignment: .bottom, spacing: 3) {
                let peak = max(30, goal.perDay.max() ?? 0)
                ForEach(Array(goal.perDay.suffix(14).enumerated()), id: \.offset) { _, m in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(m >= 5 ? Color.accentColor.opacity(0.75) : Color.gray.opacity(0.25))
                        .frame(width: 10, height: max(3, 34 * m / peak))
                }
            }
            .frame(height: 34, alignment: .bottom)
            .help("Minutes on screen per day")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.08)))
    }

    private var detail: String {
        var parts: [String] = []
        for (k, v) in goal.outputs.sorted(by: { $0.key < $1.key }) {
            let label = k == "applications" ? "applications" : "LeetCode problems"
            parts.append("\(v)\(goal.outputTargets[k].map { " of \($0)" } ?? "") \(label)")
        }
        parts.append(goal.daysTouched == 1 ? "1 day with 5+ min" : "\(goal.daysTouched) days with 5+ min")
        if let last = goal.lastTouched { parts.append("last seen \(last.formatted(.relative(presentation: .named)))") }
        else { parts.append("not seen") }
        return parts.joined(separator: " · ")
    }
}

private struct ReportView: View {
    let report: InsightsReport.Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.headline).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !report.goals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.goals, id: \.goal) { g in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(g.goal).font(.system(size: 13, weight: .semibold)).frame(width: 120, alignment: .leading)
                            Text(g.verdict).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(g.verdict == "behind" || g.verdict == "untouched" ? .orange : g.verdict == "no data" ? .secondary : .green)
                                .frame(width: 80, alignment: .leading)
                            Text(g.line).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            block("Takeaways") {
                ForEach(Array(report.takeaways.enumerated()), id: \.offset) { i, t in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(i + 1). \(t.title)").font(.system(size: 14, weight: .semibold))
                        Text(t.detail).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text(t.evidence).font(.system(size: 12)).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            block("Try this week") {
                ForEach(Array(report.tips.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).font(.system(size: 14, weight: .semibold))
                        Text(t.detail).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Text("Measured by: \(t.measure)").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            if !report.working.isEmpty {
                block("What's working") {
                    ForEach(report.working, id: \.self) { Text("· " + $0).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if !report.lastTips.isEmpty {
                block("Last week's tips") {
                    ForEach(report.lastTips, id: \.tip) { t in
                        Text("\(t.tip): \(t.followed). \(t.effect)").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let q = report.goalQuestion {
                Text(q).font(.system(size: 13, weight: .medium)).padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)))
            }
        }
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }
}

/// Edit, reorder, add and drop goals. Saving records what changed.
private struct GoalsEditor: View {
    @State var goals: [Goals.Goal]
    let onSave: ([Goals.Goal]) -> Void
    @Environment(\.dismiss) private var dismiss
    private let categories = ScreenCoach.shared?.appSettings.tags ?? ["Math", "SWE", "AI", "HW", "LeetCode", "Recruiting"]
    private let courses = CoachCourse.known.map(\.code)

    init(initial: [Goals.Goal], onSave: @escaping ([Goals.Goal]) -> Void) {
        _goals = State(initialValue: initial.filter { !$0.archived })
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your goals").font(.system(size: 20, weight: .semibold))
                    Text("Top first. Mark the ones you put off: Focus measures and nudges those first.")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Add goal") { goals.append(Goals.Goal(title: "New goal")) }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach($goals) { $g in
                        let i = goals.firstIndex { $0.id == g.id } ?? 0
                        GoalEditorCard(goal: $g, rank: i + 1, categories: categories, courses: courses,
                                       up: i > 0 ? { goals.swapAt(i, i - 1) } : nil,
                                       down: i < goals.count - 1 ? { goals.swapAt(i, i + 1) } : nil,
                                       remove: { goals.removeAll { $0.id == g.id } })
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(goals)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 720, height: 720)
    }
}

private struct GoalEditorCard: View {
    @Binding var goal: Goals.Goal
    let rank: Int
    let categories: [String]
    let courses: [String]
    let up: (() -> Void)?
    let down: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rank).").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                TextField("Goal", text: $goal.title).textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .semibold))
                Button { up?() } label: { Image(systemName: "chevron.up").foregroundStyle(Color.accentColor).iconTarget(28) }
                    .buttonStyle(.plainHit).disabled(up == nil).help("Move up").accessibilityLabel("Move up")
                Button { down?() } label: { Image(systemName: "chevron.down").foregroundStyle(Color.accentColor).iconTarget(28) }
                    .buttonStyle(.plainHit).disabled(down == nil).help("Move down").accessibilityLabel("Move down")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash").foregroundStyle(.red).iconTarget(28) }
                    .buttonStyle(.plainHit).help("Remove goal").accessibilityLabel("Remove goal")
            }
            TextField("Why, or what done looks like", text: $goal.why).textFieldStyle(.roundedBorder)
            Toggle("I put this off (measure it first and nudge me)", isOn: $goal.avoided)
            chips("Time in", options: categories, selected: $goal.categories)
            chips("Courses", options: courses, selected: $goal.courses)
            HStack(spacing: 24) {
                Stepper(value: Binding(get: { goal.weeklyHours ?? 0 }, set: { goal.weeklyHours = $0 > 0 ? $0 : nil }), in: 0...60, step: 1) {
                    Text("Weekly target: \(goal.weeklyHours.map { "\(Int($0)) h" } ?? "none")")
                }
                Stepper(value: Binding(get: { goal.dailyMinutes ?? 0 }, set: { goal.dailyMinutes = $0 > 0 ? $0 : nil }), in: 0...240, step: 15) {
                    Text("Daily minimum: \(goal.dailyMinutes.map { "\(Int($0)) min" } ?? "none")")
                }
            }.font(.system(size: 13))
            HStack(spacing: 24) {
                ForEach(Goals.Output.allCases) { o in
                    let on = Binding(get: { goal.outputs.contains(o) }, set: { v in
                        if v { goal.outputs.append(o) } else { goal.outputs.removeAll { $0 == o } }
                    })
                    Toggle(o.label, isOn: on)
                    if goal.outputs.contains(o) {
                        Stepper(value: Binding(get: { goal.outputsPerWeek[o.rawValue] ?? 0 }, set: { goal.outputsPerWeek[o.rawValue] = $0 }), in: 0...50) {
                            Text("\(goal.outputsPerWeek[o.rawValue] ?? 0)/week").monospacedDigit()
                        }
                    }
                }
            }.font(.system(size: 13))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.08)))
    }

    private func chips(_ label: String, options: [String], selected: Binding<[String]>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText).frame(width: 60, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { o in
                        let on = selected.wrappedValue.contains(o)
                        Button(o) {
                            if on { selected.wrappedValue.removeAll { $0 == o } } else { selected.wrappedValue.append(o) }
                        }
                        .buttonStyle(.plainHit).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? categoryColor(o).opacity(0.22) : Color.gray.opacity(0.12)))
                    }
                }
            }
        }
    }
}
