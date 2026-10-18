import AppKit
import Charts
import FocusCore
import SwiftUI

// MARK: - Window controller

@MainActor
final class LeetCodeWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func open(store: LeetCodeStore, settings: AppSettings) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = LeetCodeView(store: store, catalog: store.catalog, settings: settings)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "LeetCode"
        w.setContentSize(NSSize(width: 1120, height: 800))
        w.minSize = NSSize(width: 920, height: 620)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private let lcOrange = Color(red: 0.98, green: 0.63, blue: 0.16)

private extension ProblemDifficulty {
    var short: String {
        switch self { case .easy: return "Easy"; case .medium: return "Med."; case .hard: return "Hard" }
    }
}

private func openOnLeetCode(_ p: LCProblem) {
    if let url = URL(string: p.url) { NSWorkspace.shared.open(url) }
}

private func relative(_ d: Date) -> String {
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                               to: Calendar.current.startOfDay(for: Date())).day ?? 0
    switch days {
    case 0: return "today"
    case 1: return "yesterday"
    default: return "\(days)d ago"
    }
}

// MARK: - Main view

struct LeetCodeView: View {
    @ObservedObject var store: LeetCodeStore
    @ObservedObject var catalog: LeetCodeCatalog
    @ObservedObject var settings: AppSettings

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", todo = "To do", solved = "Solved", review = "Review"
        var id: String { rawValue }
    }
    enum Tab: String, CaseIterable, Identifiable {
        case grind = "Grind", stats = "Stats"
        var id: String { rawValue }
    }
    enum PickMode { case smart, random }

    @State private var query = ""
    @State private var difficulty: ProblemDifficulty?
    @State private var status: StatusFilter = .all
    @State private var pattern: String?
    @State private var list: LCList?
    @AppStorage("leetCode.hidePremium") private var hidePremium = true
    @State private var selectedSlug: String?
    @State private var tab: Tab = .grind
    @State private var logTarget: LCProblem?
    @State private var pick: LCPick?
    @State private var pickMode: PickMode = .smart

    private var filtered: [LCProblem] {
        var pool = catalog.problems
        if hidePremium { pool = pool.filter { !$0.paidOnly } }
        if let difficulty { pool = pool.filter { $0.difficulty == difficulty } }
        if let pattern { pool = pool.filter { $0.category == pattern } }
        if let list { pool = pool.filter { $0.isIn(list) } }
        switch status {
        case .all: break
        case .todo: pool = pool.filter { !store.solvedSlugs.contains($0.slug) }
        case .solved: pool = pool.filter { store.solvedSlugs.contains($0.slug) }
        case .review:
            let due = Set(store.reviewQueue.map(\.problem.slug))
            pool = pool.filter { due.contains($0.slug) }
        }
        return catalog.search(query, in: pool)
    }

    private var selectedProblem: LCProblem? { selectedSlug.flatMap(catalog.problem(slug:)) }

    var body: some View {
        let items = filtered
        HStack(spacing: 0) {
            browser(items)
                .frame(width: 440)
            Divider()
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .grind: grindTab(items)
                        case .stats: statsTab
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 920, minHeight: 620)
        .overlay(alignment: .top) { celebrationBanner }
        .onChange(of: selectedSlug) { _, slug in
            if let slug, let problem = catalog.problem(slug: slug) { store.start(problem) }
        }
        .sheet(item: $logTarget) { p in
            LCLogSheet(problem: p, suggestedMinutes: store.elapsedMinutes(for: p)) { details in
                let saved = store.log(p, confidence: details.confidence, minutes: details.minutes,
                    usedHelp: details.usedHelp, notes: details.notes, title: details.title,
                    difficulty: details.difficulty, categories: details.categories)
                if saved, pick?.problem.slug == p.slug { pick = nil }
                return saved
            }
        }
        .sheet(item: $store.finishingPractice) { session in
            LCLogSheet(problem: store.problem(for: session), suggestedMinutes: session.minutes,
                       allowUnsolved: true, workedAt: session.startedAt, draft: session.draftDetails,
                       onDefer: { store.keepPracticeDetails(id: session.id, details: $0) }) { details in
                store.completePractice(session, details: details)
            }
        }
    }

    // MARK: Browser

    private func browser(_ items: [LCProblem]) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search by number or title — “146”, “lru cache”", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = items.first { selectedSlug = first.slug } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            HStack(spacing: 5) {
                filterChip("All", selected: difficulty == nil, color: .secondary) { difficulty = nil }
                ForEach(ProblemDifficulty.allCases, id: \.self) { d in
                    filterChip(d.rawValue, selected: difficulty == d, color: d.color) {
                        difficulty = difficulty == d ? nil : d
                    }
                }
                Spacer()
                Picker("", selection: $status) {
                    ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            HStack(spacing: 10) {
                Menu {
                    Button("Any pattern") { pattern = nil }
                    Divider()
                    ForEach(ProblemDomain.swe.categories, id: \.self) { c in Button(c) { pattern = c } }
                } label: { Text(pattern ?? "Pattern").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Menu {
                    Button("All problems") { list = nil }
                    Divider()
                    ForEach(LCList.allCases) { l in Button(l.title) { list = l } }
                } label: { Text(list?.title ?? "List").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if pattern != nil || list != nil || difficulty != nil || status != .all || !query.isEmpty {
                    Button("Clear filters") {
                        pattern = nil; list = nil; difficulty = nil; status = .all; query = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Hide premium", isOn: $hidePremium)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }

            HStack {
                Text("\(items.count) problems")
                Spacer()
                Text("\(store.uniqueSolved) solved")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            List(items, selection: $selectedSlug) { p in
                LCRow(problem: p, status: store.status(of: p), active: store.activeSlug == p.slug)
                    .contextMenu {
                        Button("Open on LeetCode") { openOnLeetCode(p) }
                        Button("Start timer") { store.start(p); selectedSlug = p.slug }
                        Button("Mark solved…") { logTarget = p }
                    }
            }
            .listStyle(.inset)
            .onChange(of: selectedSlug) { _, slug in if slug != nil { tab = .grind } }
        }
        .padding(12)
    }

    private func filterChip(_ label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? color : Color.secondary)
                .background(Capsule().fill(selected ? color.opacity(0.16) : Color.secondary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Grind tab

    @ViewBuilder
    private func grindTab(_ items: [LCProblem]) -> some View {
        todayCard
        if let p = store.activeProblem { activeCard(p) }
        practiceSessionsCard
        if let p = selectedProblem, p.slug != store.activeSlug { problemCard(p) }
        pickCard(items)
        if !store.reviewQueue.isEmpty { reviewCard }
        paceCard
    }

    private var todayCard: some View {
        let goal = store.dailyGoal
        let count = store.todayCount
        let last7 = store.count(lastDays: 7)
        let prior7 = store.count(lastDays: 7, endingDaysAgo: 7)
        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().stroke(lcOrange.opacity(0.15), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: min(1, Double(count) / Double(max(goal, 1))))
                    .stroke(count >= goal ? Color.green : lcOrange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: count)
                VStack(spacing: 0) {
                    Text("\(count)/\(goal)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("today").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 6) {
                Text(count >= goal ? "Goal hit. Keep stacking." : "\(goal - count) to go today")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(store.todayNew) new · \(store.todayRedo) redo · \(store.todayPoints) pts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("Daily goal").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Stepper("\(goal)", value: Binding(get: { goal }, set: { store.setDailyGoal($0) }), in: 1...30)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                }
            }
            Spacer()
            statBlock(value: "\(store.streak)", label: store.streakAtRisk ? "streak — on the line" : "day streak",
                      sub: "best \(store.bestStreak)", icon: "flame.fill",
                      color: store.streakAtRisk ? .red : (store.streak > 0 ? lcOrange : .secondary))
            statBlock(value: "\(last7)", label: "last 7 days",
                      sub: prior7 > 0 ? "\(last7 >= prior7 ? "+" : "")\(last7 - prior7) vs prior week" : "—",
                      icon: "calendar", color: .blue)
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private func statBlock(value: String, label: String, sub: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(sub).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    private var practiceSessionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Practice sessions").font(.system(size: 15, weight: .semibold))
            Text("Work is saved automatically. Finish the log when you’re ready.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            if store.recentPractice.isEmpty {
                Text("Choose a problem or open a LeetCode problem page to begin.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            ForEach(store.recentPractice.filter { $0.id != store.practice.activeID }.prefix(5)) { session in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.system(size: 13, weight: .medium))
                        Text("\(durationText(minutes: session.seconds / 60)) · \(session.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(session.outcome == .draft ? "Details pending" : session.outcome == .solved ? "Solve logged" : "Not solved yet")")
                            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    if session.outcome == .draft {
                        Button("Resume") { store.resumePractice(session) }
                        Button("Finish log") { store.reviewPractice(session) }
                    } else if session.outcome == .unsolved {
                        Button("Try again") { store.start(store.problem(for: session)) }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
    }

    private func activeCard(_ p: LCProblem) -> some View {
        let seconds = Int(store.activeSeconds)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.workingOnProblem ? "Working on" : "Paused problem")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    Text(p.number > 0 ? "\(p.number). \(p.title)" : p.title)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(p.category.isEmpty ? "Check difficulty and pattern when you log" : "\(p.difficulty.rawValue) · \(p.category)")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button("Open problem") { openOnLeetCode(p) }
                Spacer()
                if store.workingOnProblem {
                    Button("Done with problem") { store.finishPractice() }
                        .buttonStyle(.borderedProminent)
                } else if let session = store.activePractice {
                    Button("Resume") { store.resumePractice(session) }
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.05)))
    }

    private func problemCard(_ p: LCProblem) -> some View {
        let history = store.history(of: p)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(p.number). \(p.title)").font(.system(size: 16, weight: .semibold))
                if p.paidOnly { Image(systemName: "lock.fill").foregroundStyle(.tertiary) }
                Spacer()
                Button { selectedSlug = nil } label: { Image(systemName: "xmark").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                pill(p.difficulty.rawValue, color: p.difficulty.color)
                pill(p.category, color: .blue)
                pill("\(Int(p.acceptance))% acceptance", color: .secondary)
                ForEach(LCList.allCases.filter { p.isIn($0) }) { l in pill(l.title, color: .yellow) }
            }
            if !p.tags.isEmpty {
                Text(p.tags.prefix(8).map { $0.replacingOccurrences(of: "-", with: " ") }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button {
                    store.start(p)
                    openOnLeetCode(p)
                } label: { Label("Start + open", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(lcOrange)
                Button("Open on LeetCode") { openOnLeetCode(p) }
                Button("Mark solved…") { logTarget = p }
            }
            if !history.isEmpty {
                Divider()
                Text("YOUR ATTEMPTS").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.tertiary)
                ForEach(history) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(a.entry.confidence.color).frame(width: 7, height: 7)
                        Text(a.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(a.entry.confidence.rawValue).font(.system(size: 11, weight: .medium))
                        if let m = a.entry.solveMinutes { Text("\(m)m").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if a.entry.needsReview { Text("used help").font(.system(size: 10)).foregroundStyle(.orange) }
                        if !a.entry.notes.isEmpty {
                            Text("— \(a.entry.notes)").font(.system(size: 11)).italic().lineLimit(2)
                        }
                        Spacer()
                    }
                    .contextMenu { Button("Delete this attempt", role: .destructive) { store.delete(a) } }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    private func pickCard(_ items: [LCProblem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("What next?")
                Spacer()
                Button {
                    pickMode = .smart
                    pick = store.smartPick(includePremium: !hidePremium)
                } label: { Label("Smart pick", systemImage: "sparkles") }
                Button {
                    pickMode = .random
                    pick = store.randomPick(from: items, includePremium: !hidePremium)
                } label: { Label("Random", systemImage: "dice") }
                    .help("Random unsolved problem from the current filters")
            }
            if let pick {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pick.problem.number). \(pick.problem.title)")
                            .font(.system(size: 14, weight: .semibold))
                        HStack(spacing: 6) {
                            pill(pick.problem.difficulty.rawValue, color: pick.problem.difficulty.color)
                            pill(pick.problem.category, color: .blue)
                            pill("\(Int(pick.problem.acceptance))%", color: .secondary)
                        }
                        ForEach(pick.reasons, id: \.self) { r in
                            Label(r, systemImage: "arrow.turn.down.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            store.start(pick.problem)
                            selectedSlug = pick.problem.slug
                            openOnLeetCode(pick.problem)
                        } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(lcOrange)
                        Button("Another") {
                            self.pick = pickMode == .smart
                                ? store.smartPick(includePremium: !hidePremium)
                                : store.randomPick(from: items, includePremium: !hidePremium)
                        }
                    }
                }
            } else {
                Text("Smart pick aims at your weakest pattern and the difficulty you're under-doing, favouring NeetCode 150 / Grind 169 problems. Random respects the filters on the left.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Redo queue")
                Text("\(store.reviewQueue.count) due").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Spacer()
                Button("Show all") { status = .review }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(store.reviewQueue.prefix(5)) { a in
                HStack(spacing: 8) {
                    Circle().fill(a.entry.confidence.color).frame(width: 7, height: 7)
                    Text("\(a.problem.number). \(a.problem.title)").font(.system(size: 12)).lineLimit(1)
                    Text(a.entry.needsReview ? "used help" : a.entry.confidence.rawValue.lowercased())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("from \(relative(a.date))").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button("Redo") {
                        store.start(a.problem)
                        selectedSlug = a.problem.slug
                        openOnLeetCode(a.problem)
                    }
                    .controlSize(.small)
                }
            }
            Text("Shaky, struggled or hinted solves come back after 1–3 days. Redo them cold.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private var paceCard: some View {
        let target = settings.leetCodeTarget
        let solved = store.uniqueSolved
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Grind target")
                Spacer()
                Stepper("\(target) problems", value: $settings.leetCodeTarget, in: 10...1000, step: 10)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                if store.deadline != nil {
                    DatePicker("by", selection: Binding(
                        get: { store.deadline ?? Date() },
                        set: { settings.leetCodeDeadline = $0 }
                    ), in: Date()..., displayedComponents: .date)
                    .font(.system(size: 11))
                    .fixedSize()
                } else {
                    Button("Set deadline") {
                        settings.leetCodeDeadline = Calendar.current.date(byAdding: .day, value: 21, to: Date())
                    }
                }
            }
            ProgressView(value: Double(min(solved, target)), total: Double(max(target, 1)))
                .tint(lcOrange)
            HStack(alignment: .firstTextBaseline) {
                Text("\(solved)/\(target) unique solved")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let needed = store.neededPerDay, let left = store.daysLeft {
                    let onPace = store.recentPace >= needed
                    Label(onPace ? "On pace" : "Behind pace",
                          systemImage: onPace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(onPace ? .green : .orange)
                    Text("need \(String(format: "%.1f", needed))/day for \(left)d · doing \(String(format: "%.1f", store.recentPace))/day")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let projected = store.projectedTotal, let d = store.deadline {
                Text("At your last-7-day pace you'll reach ~\(projected) by \(d.formatted(.dateTime.month(.abbreviated).day())).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    // MARK: Stats tab

    @ViewBuilder
    private var statsTab: some View {
        summaryRow
        chartCard
        patternCard
        HStack(alignment: .top, spacing: 14) {
            mixCard
            speedCard
        }
        HStack(alignment: .top, spacing: 14) {
            qualityCard
            listsCard
        }
        milestonesCard
        catalogFooter
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.uniqueSolved)").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("unique solved · \(store.attempts.count) attempts").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(ProblemDifficulty.allCases, id: \.self) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.uniqueSolved(d))")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(d.color)
                    Text("\(d.rawValue) / \(store.catalogCount(d))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 80, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.bestDay)").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("best day").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .leading)
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private var chartCard: some View {
        let days = store.series(days: 28)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Last 28 days")
                Spacer()
                Text("dashed line = daily goal").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(days) { day in
                    ForEach([(ProblemDifficulty.easy, day.easy), (.medium, day.medium), (.hard, day.hard)], id: \.0) { d, n in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Solved", n))
                            .foregroundStyle(by: .value("Difficulty", d.rawValue))
                    }
                }
                RuleMark(y: .value("Goal", store.dailyGoal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
            .chartForegroundStyleScale([
                "Easy": ProblemDifficulty.easy.color,
                "Medium": ProblemDifficulty.medium.color,
                "Hard": ProblemDifficulty.hard.color,
            ])
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
            .frame(height: 150)
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private var patternCard: some View {
        let stats = store.patternStats
        let focus = Set(store.weakestPatterns.prefix(3).map(\.category))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Pattern coverage")
                Spacer()
                Text("orange = focus next · click to filter").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(stats) { s in
                    Button {
                        pattern = s.category
                        status = .todo
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.category).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text("\(s.solved)").font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule()
                                        .fill(confidenceColor(s.avgConfidence))
                                        .frame(width: geo.size.width * min(1, Double(s.solved) / 10))
                                }
                            }
                            .frame(height: 4)
                            Text(s.lastPracticed.map { "last \(relative($0))" } ?? "not started")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(focus.contains(s.category) ? lcOrange.opacity(0.7) : .clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Bar fills at 10 solved; colour is average confidence. Aim for 5–10 solid solves per pattern.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private func confidenceColor(_ avg: Double?) -> Color {
        guard let avg else { return .secondary }
        return avg >= 1.5 ? Confidence.solid.color : avg >= 0.8 ? Confidence.shaky.color : Confidence.struggled.color
    }

    private var mixCard: some View {
        let mix = store.difficultyMix()
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Difficulty mix, 30 days")
            ForEach(mix, id: \.0) { d, share in
                let target = LeetCodeStore.targetMix[d]!
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(d.rawValue).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("\(Int((share * 100).rounded()))% · target \(Int(target * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(d.color).frame(width: geo.size.width * share)
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1.5)
                                .offset(x: geo.size.width * target)
                        }
                    }
                    .frame(height: 6)
                }
            }
            Text(mixAdvice(mix)).font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func mixAdvice(_ mix: [(ProblemDifficulty, Double)]) -> String {
        guard store.attempts.count >= 5 else { return "Interviews are mostly Mediums — let them be ~60% of your reps." }
        let gaps = mix.map { ($0.0, LeetCodeStore.targetMix[$0.0]! - $0.1) }
        guard let biggest = gaps.max(by: { $0.1 < $1.1 }), biggest.1 > 0.08 else { return "Mix looks interview-shaped. Keep it." }
        return "Lean into \(biggest.0.rawValue)s — you're \(Int((biggest.1 * 100).rounded())) pts under target."
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Median solve time")
            ForEach(ProblemDifficulty.allCases, id: \.self) { d in
                let target = LeetCodeStore.targetMinutes[d]!
                HStack {
                    Circle().fill(d.color).frame(width: 7, height: 7)
                    Text(d.rawValue).font(.system(size: 11, weight: .medium))
                    Spacer()
                    if let m = store.medianMinutes(d) {
                        Text("\(m)m").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(m <= target ? Color.green : .orange)
                        if let t = store.speedTrend(d), t != 0 {
                            Image(systemName: t < 0 ? "arrow.down.right" : "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(t < 0 ? .green : .orange)
                                .help(t < 0 ? "Getting faster" : "Getting slower")
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                    Text("/ \(target)m").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text("Targets are interview pace. Use Start so times are real, not guessed.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private var qualityCard: some View {
        let split = store.confidenceSplit()
        let total = max(1, split.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Quality, last 30")
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(split, id: \.0) { c, n in
                        Rectangle().fill(c.color).frame(width: geo.size.width * Double(n) / Double(total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach(split, id: \.0) { c, n in
                    HStack(spacing: 3) {
                        Circle().fill(c.color).frame(width: 6, height: 6)
                        Text("\(c.rawValue) \(n)").font(.system(size: 10))
                    }
                }
            }
            if let r = store.independentRate {
                Text("\(Int((r * 100).rounded()))% solved without hints or AI")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(r >= 0.8 ? Color.green : r >= 0.6 ? .orange : .red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private var listsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Curated lists")
            ForEach(LCList.allCases) { l in
                let p = store.progress(in: l)
                Button { list = l; status = .todo } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(l.title).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(p.solved)/\(p.total)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(p.solved), total: Double(max(p.total, 1)))
                            .tint(p.solved == p.total ? .green : .yellow)
                            .controlSize(.small)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private var milestonesCard: some View {
        let all = store.milestones
        let unlocked = all.filter(\.unlocked)
        let next = all.filter { !$0.unlocked }.sorted { $0.progress > $1.progress }.prefix(4)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Milestones")
                Text("\(unlocked.count)/\(all.count)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !unlocked.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], spacing: 6) {
                    ForEach(unlocked) { m in
                        HStack(spacing: 5) {
                            Image(systemName: m.icon).foregroundStyle(lcOrange)
                            Text(m.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(lcOrange.opacity(0.12)))
                    }
                }
            }
            ForEach(Array(next)) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.icon).foregroundStyle(.tertiary).frame(width: 16)
                    Text(m.title).font(.system(size: 11)).frame(width: 150, alignment: .leading)
                    ProgressView(value: m.progress).tint(lcOrange).controlSize(.small)
                    Text("\(m.current)/\(m.goal)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 12)
    }

    private var catalogFooter: some View {
        HStack(spacing: 8) {
            Text("\(catalog.problems.count) LeetCode algorithm problems · list from \(String(catalog.generated.prefix(10)))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let msg = catalog.refreshMessage {
                Text(msg).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if catalog.isRefreshing { ProgressView().controlSize(.small) }
            Button("Update from LeetCode") { Task { await catalog.refreshFromLeetCode() } }
                .disabled(catalog.isRefreshing)
                .controlSize(.small)
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .semibold))
    }

    @ViewBuilder
    private var celebrationBanner: some View {
        if let text = store.celebration {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(lcOrange)
                Text(text).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassCard(in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { store.celebration = nil }
            }
        }
    }
}

// MARK: - Row

private struct LCRow: View {
    let problem: LCProblem
    let status: LCStatus
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            statusIcon.frame(width: 14)
            Text("\(problem.number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(problem.title).font(.system(size: 12)).lineLimit(1)
            if problem.paidOnly {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if active {
                Image(systemName: "stopwatch.fill").font(.system(size: 10)).foregroundStyle(lcOrange)
            }
            Spacer(minLength: 4)
            if problem.isIn(.neetcode150) || problem.isIn(.blind75) || problem.isIn(.grind169) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .help(LCList.allCases.filter { problem.isIn($0) }.map(\.title).joined(separator: ", "))
            }
            Text("\(Int(problem.acceptance))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
            Text(problem.difficulty.short)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(problem.difficulty.color)
                .frame(width: 34, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .todo:
            Image(systemName: "circle").font(.system(size: 10)).foregroundStyle(.quaternary)
        case .solved(let c):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(c.color)
        case .reviewDue:
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        }
    }
}

// MARK: - Log sheet

struct LCLogSheet: View {
    let problem: LCProblem
    let allowUnsolved: Bool
    let workedAt: Date?
    let onSave: (LeetCodeLogDetails) -> Bool
    let onDefer: ((LeetCodePracticeState.Details) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var difficulty: ProblemDifficulty?
    @State private var categories: Set<String>
    @State private var outcome: String
    @State private var confidence: Confidence?
    @State private var minutes: Int
    @State private var timed: Bool
    @State private var usedHelp = false
    @State private var notes = ""
    @State private var error: String?
    private let wasTimed: Bool

    init(problem: LCProblem, suggestedMinutes: Int?, allowUnsolved: Bool = false, workedAt: Date? = nil,
         previewReady: Bool = false, draft: LeetCodePracticeState.Details? = nil,
         onDefer: ((LeetCodePracticeState.Details) -> Void)? = nil, onSave: @escaping (LeetCodeLogDetails) -> Bool) {
        self.problem = problem; self.allowUnsolved = allowUnsolved; self.workedAt = workedAt; self.onSave = onSave; self.onDefer = onDefer
        wasTimed = suggestedMinutes != nil
        _title = State(initialValue: draft?.title ?? problem.title)
        _difficulty = State(initialValue: draft?.difficulty ?? (problem.number == 0 && problem.category.isEmpty ? nil : problem.difficulty))
        _categories = State(initialValue: Set(draft?.categories ?? problem.categories))
        _outcome = State(initialValue: draft?.solved.map { $0 ? "Solved" : "Not solved yet" } ?? (allowUnsolved && !previewReady ? "" : "Solved"))
        _confidence = State(initialValue: draft?.confidence ?? (previewReady ? .shaky : nil))
        _minutes = State(initialValue: draft?.minutes ?? suggestedMinutes ?? 1)
        _timed = State(initialValue: draft.map { $0.minutes != nil } ?? (suggestedMinutes != nil))
        _usedHelp = State(initialValue: draft?.usedHelp ?? false)
        _notes = State(initialValue: draft?.notes ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !categories.isEmpty
            && confidence != nil && difficulty != nil && !outcome.isEmpty
    }

    private var missingFields: String {
        var fields: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("a title") }
        if difficulty == nil { fields.append("difficulty") }
        if categories.isEmpty { fields.append("a pattern") }
        if outcome.isEmpty { fields.append("an outcome") }
        if confidence == nil { fields.append("confidence") }
        return "Choose " + fields.joined(separator: ", ") + " to save."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(allowUnsolved ? "Finish your practice log" : "Log your solve")
                .font(.system(size: 22, weight: .semibold))
            Text(workedAt.map { "Started \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute())). Your work time is already saved." }
                 ?? "Check the problem details, then record how it went.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Problem title", text: $title).textFieldStyle(.roundedBorder)
                    Text("Difficulty").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(ProblemDifficulty.allCases, id: \.self) { choice in
                            Button { difficulty = choice } label: {
                                Text(choice.rawValue).frame(maxWidth: .infinity, minHeight: 36)
                                    .background(Capsule().fill(difficulty == choice ? categoryColor(FocusCategories.leetCode).opacity(0.2) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(difficulty == choice ? .isSelected : [])
                        }
                    }
                    Menu {
                        ForEach(ProblemDomain.swe.categories, id: \.self) { category in
                            Button {
                                if categories.contains(category) { categories.remove(category) } else { categories.insert(category) }
                            } label: {
                                if categories.contains(category) { Label(category, systemImage: "checkmark") } else { Text(category) }
                            }
                        }
                    } label: { Text(categories.isEmpty ? "Choose a pattern" : categories.sorted().joined(separator: ", ")).lineLimit(1) }
                    if let url = URL(string: problem.url) { Link("Open problem page", destination: url) }

                    if allowUnsolved {
                        Picker("Outcome", selection: $outcome) {
                            Text("Choose outcome").tag("")
                            Text("Solved").tag("Solved")
                            Text("Not solved yet").tag("Not solved yet")
                        }
                    }
                    Text("How did it go?").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(Confidence.allCases, id: \.self) { choice in
                            Button { confidence = choice } label: {
                                Text(choice.rawValue).font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(Capsule().fill(confidence == choice ? categoryColor(FocusCategories.leetCode).opacity(0.2) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(confidence == choice ? .isSelected : [])
                        }
                    }
                    Toggle("Record work time", isOn: $timed)
                    if timed {
                        Stepper("\(minutes) minutes", value: $minutes, in: 1...1440)
                        Text(wasTimed ? "From tracked work; pauses and app downtime are excluded. You can correct it." : "Enter only the time you know you spent.")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                    Toggle("Used hints, AI or the solution", isOn: $usedHelp)
                    Text("Key insight or what blocked you").font(.system(size: 13, weight: .semibold))
                    TextField("The pattern, mistake or next step", text: $notes, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                    Text(outcome == "Not solved yet" ? "Saved as practice. It will not count toward your solve goal." : "Confidence and help used set the existing review schedule.")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
                .font(.system(size: 13))
            }
            .scrollIndicators(.visible)
            if !canSave { Text(missingFields).font(.system(size: 12)).foregroundStyle(Color.secondaryText) }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Button(allowUnsolved ? "Finish later" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(outcome == "Not solved yet" ? "Save practice" : "Log solve") {
                    guard let confidence, let difficulty else { return }
                    let details = LeetCodeLogDetails(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        difficulty: difficulty, categories: categories.sorted(), solved: outcome == "Solved",
                        confidence: confidence, minutes: timed ? minutes : nil, usedHelp: usedHelp,
                        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
                    if onSave(details) { dismiss() } else { error = "Couldn’t save. Your practice draft is safe; try again." }
                }
                .disabled(!canSave).keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(20).frame(width: 460, height: 620)
        .onDisappear {
            onDefer?(.init(title: title, difficulty: difficulty, categories: categories.sorted(),
                           solved: outcome.isEmpty ? nil : outcome == "Solved", confidence: confidence,
                           minutes: timed ? minutes : nil, usedHelp: usedHelp, notes: notes))
        }
    }
}
