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
                reportSection
                timerSection(s)
                attentionSection(s)
                daysSection(s)
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(pct(s.avoidedShare)).font(.system(size: 46, weight: .semibold)).monospacedDigit()
                Text("of your focus went to \(avoided.isEmpty ? "the goals you put off" : avoided.joined(separator: " and "))")
                    .font(.system(size: 15, weight: .medium))
            }
            Text("\(hm(s.avoidedMinutes)) of \(hm(total)) of focus work the screen saw in the last \(store.days) days. First block of the day went there on \(s.avoidedFirstDays) of \(s.days.filter { $0.firstFocus != nil }.count) days.")
                .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
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
            if let r = store.latest { ReportView(report: r.content) }
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

    // MARK: Attention

    private func attentionSection(_ s: Insights.Summary) -> some View {
        let a = s.attention
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("When you leave the work",
                         subtitle: "Every time something else came to the front during a focus block, timed to the second. Other study doesn't count")
            HStack(spacing: 28) {
                stat(String(format: "%.1f", a.perFocusHour), "times an hour")
                stat("\(a.glances)", "glances under 30 s")
                stat("\(a.detours)", "detours up to 5 min")
                stat("\(a.drifts)", "drifts over 5 min")
                stat(hm(a.medianStretchMinutes), "typical stretch on task")
                stat(hm(a.longestStretchMinutes), "longest stretch")
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where it went").font(.system(size: 13, weight: .semibold))
                    ForEach(a.distractors.prefix(8)) { d in
                        HStack {
                            Text(d.name).font(.system(size: 13))
                            Spacer()
                            Text("\(d.count)× · \(hm(d.minutes))").font(.system(size: 12)).foregroundStyle(Color.secondaryText).monospacedDigit()
                        }
                    }
                    if a.distractors.isEmpty { Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
                }.frame(width: 300)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Minutes away from the work, by hour").font(.system(size: 13, weight: .semibold))
                    Chart {
                        ForEach(Array(a.byHour.enumerated()), id: \.offset) { h, m in
                            BarMark(x: .value("Hour", h), y: .value("Minutes", m)).foregroundStyle(.orange.opacity(0.8))
                        }
                        ForEach(Array(s.studyByHour.enumerated()), id: \.offset) { h, m in
                            LineMark(x: .value("Hour", h), y: .value("Study", m / 6)).foregroundStyle(.green)
                        }
                    }
                    .chartXAxis { AxisMarks(values: [0, 6, 9, 12, 15, 18, 21]) { v in
                        AxisValueLabel { if let h = v.as(Int.self) { Text(h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p") } }
                    } }
                    .frame(height: 140)
                    Text("Bars: minutes away. Line: study on screen (÷6)").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
            Text(a.focusHoursSeen < 1 ? "Second-by-second timing starts with this version; earlier days use the 15-second screen readings."
                 : "From \(String(format: "%.1f", a.focusHoursSeen)) h of focus blocks the Mac saw. \(pct(a.longStretchShare)) of on-task time came in stretches of 25 min or more.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
    }

    // MARK: Days

    private func daysSection(_ s: Insights.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Day by day", subtitle: "When the put-off work started, if it did")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Day", "Timer focus", "On screen", "Put-off goals", "First focus", "First put-off work", "Away / hour", "AI msgs"], id: \.self) {
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
                        Text(d.excursionsPerHour.map { String(format: "%.1f", $0) } ?? "–").monospacedDigit()
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
                        HStack { Text(k.replacingOccurrences(of: "-", with: " ").capitalized); Spacer(); Text(pct(v / total)).monospacedDigit() }
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
            .frame(width: 330, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                let target = goal.target ?? 0
                ProgressView(value: min(goal.screenMinutes, max(target, 1)), total: max(target, 1))
                    .tint(target > 0 && goal.screenMinutes >= target ? .green : .orange)
                    .opacity(target > 0 ? 1 : 0.3)
                Text(target > 0 ? "\(hm(goal.screenMinutes)) of \(hm(target)) on screen · \(hm(goal.trackedMinutes)) on the timer"
                     : "\(hm(goal.screenMinutes)) on screen · \(hm(goal.trackedMinutes)) on the timer · no target")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
            .frame(width: 280)
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
        parts.append("\(goal.daysTouched) days touched")
        if let last = goal.lastTouched { parts.append("last \(last.formatted(.relative(presentation: .named)))") }
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
                Button { up?() } label: { Image(systemName: "chevron.up") }.disabled(up == nil).buttonStyle(.borderless)
                Button { down?() } label: { Image(systemName: "chevron.down") }.disabled(down == nil).buttonStyle(.borderless)
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
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
                        .buttonStyle(.plain).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(on ? categoryColor(o).opacity(0.22) : Color.gray.opacity(0.12)))
                    }
                }
            }
        }
    }
}
