import SwiftUI
import FocusCore

// MARK: - Main view

struct ProblemsView: View {
    @ObservedObject var store: ProblemStore
    @ObservedObject var homeworkStore: HomeworkStore
    @ObservedObject var settings: AppSettings

    @State private var showLog = false
    @State private var selectedProblem: ProblemEntry? = nil
    @State private var reviewExpanded = true
    @State private var editingHomework: HomeworkProblem? = nil
    // The Stat 110 catalog picker + dedicated homework-log overlay used
    // to live here. Both moved to Practice Mode where homework now lives.
    // Editing existing homework rows from the merged recent list still
    // happens via `editingHomework`.

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 12) {
                    logButton

                    if !store.needsReviewItems.isEmpty || !store.dueForReview.isEmpty {
                        reviewCard
                    }

                    if settings.interviewDate != nil {
                        countdownCard
                    }

                    goalSection

                    progressCard

                    Divider().padding(.horizontal, 8)

                    recentSection
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 18)
            }

            if showLog {
                LogProblemOverlay(store: store, settings: settings, isShowing: $showLog)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    .zIndex(1)
            }

            if let editing = editingHomework {
                HomeworkEditOverlay(
                    store: homeworkStore, settings: settings, item: editing,
                    isShowing: Binding(get: { editingHomework != nil },
                                       set: { if !$0 { editingHomework = nil } })
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                .zIndex(4)
            }

            if selectedProblem != nil {
                ProblemDetailView(
                    store: store,
                    problem: selectedProblem!,
                    isShowing: Binding(
                        get: { selectedProblem != nil },
                        set: { if !$0 { selectedProblem = nil } }
                    )
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                .zIndex(2)
            }
        }
    }

    // MARK: - Interview countdown

    private var countdownCard: some View {
        let date = settings.interviewDate!
        let days = max(0, Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)).day ?? 0)
        let totalGoal = settings.quantGoal + settings.sweGoal
        let pace: Double = (totalGoal > 0 && days > 0)
            ? Double(max(0, totalGoal - store.totalCount)) / Double(days)
            : 0

        let urgent = days <= 30
        let accent = urgent ? Color.orange : Color(red: 0.27, green: 0.62, blue: 0.83)

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interview in")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(days)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    Text("days")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if pace > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f / day", pace))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("problems to goal")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else if totalGoal == 0 {
                Text("Set a goal in Settings")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                    Text("Goal reached!")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(accent.opacity(0.06))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Goal bars

    private var goalSection: some View {
        VStack(spacing: 8) {
            ForEach(ProblemDomain.allCases, id: \.self) { domain in
                GoalBar(
                    domain: domain,
                    count: store.count(for: domain),
                    goal: domain == .quant ? settings.quantGoal : settings.sweGoal
                )
            }
        }
    }

    // MARK: - Review queue

    private var reviewCard: some View {
        let aiItems = store.needsReviewItems
        let dueItems = store.dueForReview.filter { !$0.needsReview } // avoid double-counting
        let total = aiItems.count + dueItems.count

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { reviewExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Review queue")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("\(total)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .clipShape(Capsule())
                    if !dueItems.isEmpty {
                        Text("\(dueItems.count) spaced")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: reviewExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if reviewExpanded {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach((aiItems + dueItems).prefix(6)) { item in
                        ReviewRow(item: item, store: store) { selectedProblem = item }
                    }
                    if total > 6 {
                        Text("+ \(total - 6) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
        .background(Color.orange.opacity(0.06))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Progress card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                let streak = store.problemStreak
                if streak > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text("\(streak)d streak")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            let days = store.dailyCounts(days: 7)
            let maxCount = max(1, days.map { $0.count }.max() ?? 1)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 2) {
                        if day.count > 0 {
                            Text("\(day.count)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(" ").font(.system(size: 8))
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.count > 0
                                  ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.7)
                                  : Color.secondary.opacity(0.1))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(4, 36 * CGFloat(day.count) / CGFloat(maxCount)))
                        Text(weekdayLetter(day.date))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60)

            HStack(spacing: 0) {
                let thisWeek = store.thisWeekCount
                let lastWeek = store.lastWeekCount
                let delta    = thisWeek - lastWeek
                let rate     = store.cleanSolveRate

                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(thisWeek)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        if lastWeek > 0 {
                            Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(delta >= 0 ? .green : .red)
                        }
                    }
                    Text("this week").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 26)

                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", rate * 100))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(rate >= 0.8 ? .green : rate >= 0.5 ? Color.orange : .red)
                    Text("clean").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 26)

                HStack(spacing: 6) {
                    ForEach(store.countByDifficulty(), id: \.difficulty) { item in
                        VStack(spacing: 1) {
                            Text("\(item.count)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(item.difficulty.color)
                            Text(String(item.difficulty.rawValue.prefix(1)))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            // Weak areas
            let weak = store.weakestCategories(limit: 3)
            if !weak.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Focus on")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    ForEach(weak, id: \.category) { item in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(scoreColor(item.avgScore))
                                .frame(width: 6, height: 6)
                            Text(item.category)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.count) logged")
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.04)))
    }

    private func scoreColor(_ score: Double) -> Color {
        if score < 0.7 { return Color(red: 0.96, green: 0.36, blue: 0.36) }
        if score < 1.4 { return Color(red: 0.98, green: 0.70, blue: 0.18) }
        return Color(red: 0.22, green: 0.72, blue: 0.45)
    }

    // MARK: - Log button

    private var logButton: some View {
        Button { showLog = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Log a problem")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .frame(minHeight: 26)
            .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent list (problems + homework merged)

    /// A row in the merged Recent list — either a ProblemEntry (LeetCode /
    /// quant problems the user logs manually) or a HomeworkProblem (Stat
    /// 110 catalog entries saved from Practice Mode). Both render with the
    /// same compact row shape so the user just sees "things I worked on
    /// recently" rather than two parallel taxonomies.
    private enum RecentItem: Identifiable {
        case problem(ProblemEntry)
        case homework(HomeworkProblem)
        var id: String {
            switch self {
            case .problem(let p): return "p-\(p.id.uuidString)"
            case .homework(let h): return "h-\(h.id.uuidString)"
            }
        }
        var date: Date {
            switch self {
            case .problem(let p): return p.date
            case .homework(let h): return h.date
            }
        }
    }

    /// Merge both stores, sort by date, group by calendar day, keep last 7 days.
    private var mergedRecentByDay: [(date: Date, items: [RecentItem])] {
        let cal = Calendar.current
        let all: [RecentItem] =
            store.problems.map { .problem($0) } +
            homeworkStore.items.map { .homework($0) }
        var groups: [Date: [RecentItem]] = [:]
        for item in all {
            let day = cal.startOfDay(for: item.date)
            groups[day, default: []].append(item)
        }
        return groups.map { (date: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
            .prefix(7)
            .map { $0 }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            let days = mergedRecentByDay
            if days.isEmpty {
                Text("No problems logged yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(days, id: \.date) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dayLabel(group.date))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 1)
                        ForEach(group.items.prefix(10)) { item in
                            switch item {
                            case .problem(let p):
                                Button { selectedProblem = p } label: {
                                    ProblemRow(problem: p)
                                }
                                .buttonStyle(.plain)
                            case .homework(let h):
                                Button { editingHomework = h } label: {
                                    HomeworkInlineRow(item: h)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func weekdayLetter(_ date: Date) -> String {
        let idx = Calendar.current.component(.weekday, from: date) - 1
        return ["S","M","T","W","T","F","S"][idx]
    }
}

// MARK: - Goal progress bar

private struct GoalBar: View {
    let domain: ProblemDomain
    let count: Int
    let goal: Int

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(1.0, Double(count) / Double(goal))
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: domain.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(domain.color)
                    Text(domain.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                if goal > 0 {
                    Text("\(count) / \(goal)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(count >= goal ? domain.color : .secondary)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(domain.color.opacity(0.8))
                        .frame(width: 32, alignment: .trailing)
                } else {
                    Text("\(count)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(domain.color)
                    Text("problems")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if goal > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(domain.color.opacity(0.1))
                        Capsule().fill(domain.color.opacity(0.85))
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 5)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: progress)
            }
        }
        .padding(10)
        .background(domain.color.opacity(0.05))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(domain.color.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Review queue row

private struct ReviewRow: View {
    let item: ProblemEntry
    @ObservedObject var store: ProblemStore
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? item.categories.joined(separator: " · ") : item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if !item.source.isEmpty {
                                Text(item.source)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text(item.difficulty.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(item.difficulty.color)
                            Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(item.domain.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(item.domain.color)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation { store.clearReview(id: item.id) }
            } label: {
                Text("Done")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
        }
    }
}

// MARK: - Recent problem row

private struct ProblemRow: View {
    let problem: ProblemEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(problem.confidence.color)
                .frame(width: 6, height: 6)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(problem.title.isEmpty ? problem.categories.joined(separator: " · ") : problem.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !problem.source.isEmpty {
                        Text(problem.source)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                    }
                    Text(problem.categories.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if problem.needsReview {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Text(problem.difficulty.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(problem.difficulty.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(problem.difficulty.color.opacity(0.12))
                .cornerRadius(4)
        }
        .contentShape(Rectangle())
    }
}

/// Compact row for a HomeworkProblem when it appears in the merged Recent
/// list (alongside ProblemEntry/ProblemRow). Same visual rhythm as
/// ProblemRow — confidence dot, title, source/category line, optional
/// review pill, difficulty chip — so the user reads them as the same
/// kind of thing.
private struct HomeworkInlineRow: View {
    let item: HomeworkProblem

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(item.confidence.color)
                .frame(width: 6, height: 6)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? item.source : item.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(item.source)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.isDueForReview {
                Text("DUE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.22)))
                    .foregroundStyle(.orange)
            } else if item.needsReview {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Text(item.difficulty.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(item.difficulty.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(item.difficulty.color.opacity(0.12))
                .cornerRadius(4)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Log problem overlay

struct LogProblemOverlay: View {
    @ObservedObject var store: ProblemStore
    @ObservedObject var settings: AppSettings
    @Binding var isShowing: Bool

    @State private var title: String = ""
    @State private var urlText: String = ""
    @State private var selectedSource: String = ""
    @AppStorage("logProblemDomain") private var selectedDomain: ProblemDomain = .quant
    @State private var pickedTitle: String? = nil
    @State private var showGrindBrowser = false
    @State private var selectedCategories: Set<String> = []
    @State private var selectedDifficulty: ProblemDifficulty = .medium
    @State private var selectedSolveMinutes: Int? = nil
    @State private var selectedConfidence: Confidence = .solid
    @State private var usedAIHelp = false
    @FocusState private var titleFocused: Bool

    private let solveOptions: [(String, Int?)] = [
        ("—", nil), ("< 5m", 3), ("5–15m", 10), ("15–30m", 22), ("30m+", 45)
    ]

    private var loggedGrindSlugs: Set<String> {
        Set(store.problems.compactMap { Grind75Catalog.problem(matching: $0)?.slug })
    }

    private var lcSuggestions: [LCProblem] {
        guard selectedDomain == .swe, pickedTitle == nil,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(LeetCodeCatalog.shared.search(title).prefix(6))
    }

    private var loggedLCSlugs: Set<String> {
        Set(store.problems.compactMap { LeetCodeCatalog.shared.problem(matching: $0)?.slug })
    }

    private func pickGrind(_ p: Grind75Problem) {
        prefill(title: p.title, url: p.url, difficulty: p.difficulty, categories: p.categories)
    }

    private func pickLC(_ p: LCProblem) {
        prefill(title: p.title, url: p.url, difficulty: p.difficulty, categories: p.categories)
    }

    private func prefill(title t: String, url: String, difficulty: ProblemDifficulty, categories: [String]) {
        pickedTitle = t
        title = t
        urlText = url
        selectedDifficulty = difficulty
        selectedCategories = Set(categories)
        if let lc = settings.problemSources.first(where: { $0.localizedCaseInsensitiveContains("leetcode") }) {
            selectedSource = lc
        }
        showGrindBrowser = false
        titleFocused = false
    }

    private var canLog: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespaces).isEmpty
        let hasCats  = !selectedCategories.isEmpty
        let hasSource = settings.problemSources.isEmpty || !selectedSource.isEmpty
        return hasTitle && hasCats && hasSource
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Log a problem")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button { isShowing = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {

                        // Domain
                        HStack(spacing: 8) {
                            ForEach(ProblemDomain.allCases, id: \.self) { domain in
                                let sel = selectedDomain == domain
                                Button {
                                    selectedDomain = domain
                                    selectedCategories = []
                                    pickedTitle = nil
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: domain.icon)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(domain.rawValue)
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .foregroundStyle(sel ? .white : domain.color)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(sel ? domain.color : domain.color.opacity(0.1))
                                    .cornerRadius(9)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Title — required
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Text("Name")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondaryText)
                                Text("required")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            TextField(selectedDomain == .swe ? "Search LeetCode by # or title, or type any name" : "e.g. Coin Flip Variance",
                                      text: $title)
                                .font(.system(size: 13, weight: .medium))
                                .textFieldStyle(.plain)
                                .focused($titleFocused)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.07))
                                .cornerRadius(8)
                                .onSubmit {
                                    if let top = lcSuggestions.first { pickLC(top) }
                                    else if canLog { logAndClose() }
                                }
                                .onChange(of: title) { _, new in
                                    if let t = pickedTitle, new != t { pickedTitle = nil }
                                }

                            if !lcSuggestions.isEmpty {
                                let done = loggedLCSlugs
                                VStack(spacing: 0) {
                                    ForEach(lcSuggestions) { p in
                                        LCSuggestionRow(problem: p, done: done.contains(p.slug)) { pickLC(p) }
                                    }
                                }
                                .background(Color.secondary.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }

                        if selectedDomain == .swe {
                            grind75Section
                        }

                        // Source — required if sources configured
                        if !settings.problemSources.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 4) {
                                    Text("Source")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.secondaryText)
                                    Text("required")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(settings.problemSources, id: \.self) { src in
                                            let sel = selectedSource == src
                                            Button(src) { selectedSource = sel ? "" : src }
                                                .font(.system(size: 11, weight: .medium))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.18) : Color.secondary.opacity(0.07))
                                                .foregroundStyle(sel ? Color(red: 0.27, green: 0.62, blue: 0.83) : Color.secondary)
                                                .cornerRadius(8)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.4) : Color.clear, lineWidth: 1)
                                                )
                                                .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        // Category — multi-select
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 4) {
                                Text("Category")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondaryText)
                                Text("required")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            let cols = [GridItem(.adaptive(minimum: 90), spacing: 6)]
                            LazyVGrid(columns: cols, spacing: 6) {
                                ForEach(selectedDomain.categories, id: \.self) { cat in
                                    let sel = selectedCategories.contains(cat)
                                    Button(cat) {
                                        if sel { selectedCategories.remove(cat) }
                                        else   { selectedCategories.insert(cat) }
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity)
                                    .background(sel ? selectedDomain.color.opacity(0.18) : Color.secondary.opacity(0.07))
                                    .foregroundStyle(sel ? selectedDomain.color : Color.secondary)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(sel ? selectedDomain.color.opacity(0.4) : Color.clear, lineWidth: 1)
                                    )
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Difficulty
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Difficulty")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.secondaryText)
                            HStack(spacing: 6) {
                                ForEach(ProblemDifficulty.allCases, id: \.self) { diff in
                                    let sel = selectedDifficulty == diff
                                    Button(diff.rawValue) { selectedDifficulty = diff }
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(sel ? diff.color.opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(sel ? diff.color : Color.secondary)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(sel ? diff.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                        )
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        // Solve time — optional
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 4) {
                                Text("Solve time")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondaryText)
                                Text("optional")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                            HStack(spacing: 5) {
                                ForEach(solveOptions, id: \.0) { label, value in
                                    let sel = selectedSolveMinutes == value
                                    Button(label) { selectedSolveMinutes = value }
                                        .font(.system(size: 10, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(sel ? Color(red: 0.27, green: 0.62, blue: 0.83) : Color.secondary)
                                        .cornerRadius(7)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .stroke(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.4) : Color.clear, lineWidth: 1)
                                        )
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        // Confidence
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Confidence")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.secondaryText)
                            HStack(spacing: 6) {
                                ForEach(Confidence.allCases, id: \.self) { conf in
                                    let sel = selectedConfidence == conf
                                    Button(conf.rawValue) { selectedConfidence = conf }
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(sel ? conf.color.opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(sel ? conf.color : Color.secondary)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(sel ? conf.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                        )
                                        .buttonStyle(.plain)
                                }
                            }
                        }

                        // URL — optional
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Text("Link")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.secondaryText)
                                Text("optional")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                            TextField("https://leetcode.com/problems/…", text: $urlText)
                                .font(.system(size: 11))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.secondary.opacity(0.07))
                                .cornerRadius(7)
                        }

                        // AI help
                        Button { usedAIHelp.toggle() } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Used AI assistance")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(usedAIHelp ? Color.orange : .primary)
                                    Text("Adds to review queue — redo this one yourself")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: usedAIHelp ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18))
                                    .foregroundStyle(usedAIHelp ? Color.orange : Color.secondary.opacity(0.4))
                            }
                            .padding(10)
                            .background(usedAIHelp ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.05))
                            .cornerRadius(9)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(usedAIHelp ? Color.orange.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)

                        // Log
                        Button {
                            if canLog { logAndClose() }
                        } label: {
                            Text("Log Problem")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(canLog ? .white : Color.secondary.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(canLog ? selectedDomain.color : Color.secondary.opacity(0.1))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canLog)
                    }
                    .padding(18)
                }
            }
        }
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var grind75Section: some View {
        let done = loggedGrindSlugs
        let next = Grind75Catalog.all.first { !done.contains($0.slug) }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Grind 75")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(done.count)/\(Grind75Catalog.all.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ProblemDomain.swe.color)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showGrindBrowser.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(showGrindBrowser ? "Hide" : "Browse")
                        Image(systemName: showGrindBrowser ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: Double(done.count), total: Double(Grind75Catalog.all.count))
                .tint(ProblemDomain.swe.color)
                .controlSize(.small)

            if let next, pickedTitle == nil, !showGrindBrowser {
                Button { pickGrind(next) } label: {
                    HStack(spacing: 6) {
                        Text("Next up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(next.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("W\(next.week)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }

            if showGrindBrowser {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(1...Grind75Catalog.weekCount, id: \.self) { week in
                        let items = Grind75Catalog.problems(inWeek: week)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("WEEK \(week) · \(items.filter { done.contains($0.slug) }.count)/\(items.count)")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(.tertiary)
                                .padding(.bottom, 3)
                            ForEach(items) { p in
                                Grind75Row(problem: p, done: done.contains(p.slug), showWeek: false) { pickGrind(p) }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    private func logAndClose() {
        store.add(ProblemEntry(
            title: title.trimmingCharacters(in: .whitespaces),
            domain: selectedDomain,
            categories: Array(selectedCategories),
            difficulty: selectedDifficulty,
            source: selectedSource,
            needsReview: usedAIHelp,
            confidence: selectedConfidence,
            notes: "",
            url: urlText.trimmingCharacters(in: .whitespaces),
            solveMinutes: selectedSolveMinutes
        ))
        isShowing = false
    }
}

private struct Grind75Row: View {
    let problem: Grind75Problem
    let done: Bool
    var showWeek = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(problem.difficulty.color)
                    .frame(width: 6, height: 6)
                Text(problem.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showWeek {
                    Text("W\(problem.week)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LCSuggestionRow: View {
    let problem: LCProblem
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(problem.difficulty.color).frame(width: 6, height: 6)
                Text("\(problem.number)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(problem.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(done ? .secondary : .primary)
                    .lineLimit(1)
                if problem.paidOnly {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Homework row

private struct HomeworkRow: View {
    let item: HomeworkProblem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(item.confidence.color)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? "Homework problem" : item.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if !item.source.isEmpty {
                            Text(item.source)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                        }
                        Text(item.difficulty.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(item.difficulty.color)
                        if item.usedAI {
                            Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles").font(.system(size: 8))
                                Text("AI").font(.system(size: 9))
                            }
                            .foregroundStyle(.orange)
                        }
                        if item.isDueForReview {
                            Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8))
                                Text("Review").font(.system(size: 9))
                            }
                            .foregroundStyle(Color(red: 0.62, green: 0.45, blue: 0.92))
                        } else if item.needsReview, let due = item.reviewDueDate {
                            Text("·").font(.system(size: 9)).foregroundStyle(.quaternary)
                            Text("review \(shortDateStr(due))")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(red: 0.62, green: 0.45, blue: 0.92).opacity(0.7))
                        }
                    }
                }
                Spacer()
                Text(shortDateStr(item.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortDateStr(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInYesterday(d) { return "yest" }
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: d)
    }
}

// MARK: - Homework log/edit overlays (lightweight)

private struct HomeworkFields: View {
    @Binding var title: String
    @Binding var source: String
    @Binding var url: String
    @Binding var difficulty: ProblemDifficulty
    @Binding var confidence: Confidence
    @Binding var usedAI: Bool
    @Binding var notes: String
    @Binding var needsReview: Bool
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NAME").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                TextField("Problem title", text: $title)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(7)
            }

            if !settings.problemSources.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SOURCE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(["Homework"] + settings.problemSources, id: \.self) { src in
                                let sel = source == src
                                Button(src) { source = sel ? "" : src }
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(sel ? Color.secondary.opacity(0.2) : Color.secondary.opacity(0.07))
                                    .foregroundStyle(sel ? .primary : .secondary)
                                    .cornerRadius(7)
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("DIFFICULTY").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ProblemDifficulty.allCases, id: \.self) { d in
                        let sel = difficulty == d
                        Button(d.rawValue) { difficulty = d }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sel ? d.color.opacity(0.15) : Color.secondary.opacity(0.07))
                            .foregroundStyle(sel ? d.color : .secondary)
                            .cornerRadius(7).buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("CONFIDENCE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Confidence.allCases, id: \.self) { c in
                        let sel = confidence == c
                        Button(c.rawValue) { confidence = c }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sel ? c.color.opacity(0.15) : Color.secondary.opacity(0.07))
                            .foregroundStyle(sel ? c.color : .secondary)
                            .cornerRadius(7).buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 16) {
                Toggle(isOn: $usedAI) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        Text("Used AI").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(usedAI ? .orange : .secondary)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $needsReview) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                        Text("Mark for review").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(needsReview ? Color(red: 0.62, green: 0.45, blue: 0.92) : .secondary)
                }
                .toggleStyle(.checkbox)
                .help("Adds this to the homework review queue (1 day out)")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("URL").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                TextField("https://…", text: $url)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(7)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("NOTES").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(7)
            }
        }
    }
}

struct HomeworkLogOverlay: View {
    @ObservedObject var store: HomeworkStore
    @ObservedObject var settings: AppSettings
    @Binding var isShowing: Bool
    let prefill: Stat110PickerPrefill?

    @State private var title: String
    @State private var source: String
    @State private var url: String = ""
    @State private var difficulty: ProblemDifficulty = .medium
    @State private var confidence: Confidence = .solid
    @State private var usedAI: Bool = false
    @State private var needsReview: Bool = false
    @State private var notes: String = ""

    /// Custom init so the picker's prefill actually lands on the `@State`
    /// fields. SwiftUI only honors @State default values OR an
    /// `_property = State(initialValue:)` assignment inside init; relying
    /// on `.onAppear` to copy in the prefill is racey on macOS — the body
    /// runs (with empty fields) before onAppear fires, and any keystroke
    /// the user makes in between gets clobbered.
    init(store: HomeworkStore, settings: AppSettings,
         isShowing: Binding<Bool>, prefill: Stat110PickerPrefill? = nil) {
        self.store = store
        self.settings = settings
        self._isShowing = isShowing
        self.prefill = prefill
        _title  = State(initialValue: prefill?.title  ?? "")
        _source = State(initialValue: prefill?.source ?? "Homework")
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("LOG HOMEWORK PROBLEM")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    Button { isShowing = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                Divider()
                ScrollView {
                    HomeworkFields(
                        title: $title, source: $source, url: $url,
                        difficulty: $difficulty, confidence: $confidence,
                        usedAI: $usedAI, notes: $notes,
                        needsReview: $needsReview, settings: settings
                    )
                    .padding(20)
                }
                Divider()
                Button {
                    let t = title.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    store.add(HomeworkProblem(
                        title: t, source: source,
                        difficulty: difficulty, confidence: confidence,
                        usedAI: usedAI,
                        notes: notes.trimmingCharacters(in: .whitespaces),
                        url: url.trimmingCharacters(in: .whitespaces),
                        catalogID: prefill?.catalogID,
                        needsReview: needsReview
                    ))
                    isShowing = false
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(title.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.secondary.opacity(0.2)
                                    : Color(red: 0.27, green: 0.62, blue: 0.83))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(16)
            }
        }
    }
}

struct HomeworkEditOverlay: View {
    @ObservedObject var store: HomeworkStore
    @ObservedObject var settings: AppSettings
    let item: HomeworkProblem
    @Binding var isShowing: Bool

    @State private var title = ""
    @State private var source = ""
    @State private var url = ""
    @State private var difficulty: ProblemDifficulty = .medium
    @State private var confidence: Confidence = .solid
    @State private var usedAI = false
    @State private var needsReview = false
    @State private var notes = ""

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("HOMEWORK PROBLEM")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.5).foregroundStyle(.secondary)
                    Spacer()
                    Button { isShowing = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
                Divider()
                ScrollView {
                    HomeworkFields(
                        title: $title, source: $source, url: $url,
                        difficulty: $difficulty, confidence: $confidence,
                        usedAI: $usedAI, notes: $notes,
                        needsReview: $needsReview, settings: settings
                    )
                    .padding(20)
                }
                Divider()
                HStack(spacing: 8) {
                    Button {
                        store.delete(id: item.id)
                        isShowing = false
                    } label: {
                        Text("Delete")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button {
                        var updated = item
                        updated.title = title.trimmingCharacters(in: .whitespaces)
                        updated.source = source
                        updated.url = url.trimmingCharacters(in: .whitespaces)
                        updated.difficulty = difficulty
                        updated.confidence = confidence
                        updated.usedAI = usedAI
                        updated.notes = notes.trimmingCharacters(in: .whitespaces)
                        updated.needsReview = needsReview
                        store.update(updated)
                        isShowing = false
                    } label: {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color(red: 0.27, green: 0.62, blue: 0.83))
                            .cornerRadius(8)
                    }.buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .onAppear {
            title = item.title
            source = item.source
            url = item.url
            difficulty = item.difficulty
            confidence = item.confidence
            usedAI = item.usedAI
            notes = item.notes
            needsReview = item.needsReview
        }
    }
}
