import SwiftUI
import SwiftData
import FocusCore

/// Automatic pattern observations. Each insight is computed at view-time
/// from the SwiftData store and worded like a friend would mention it.
struct InsightsScreen: View {
    @EnvironmentObject var settings: PadSettings
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredProblem.date, order: .reverse) private var problems: [StoredProblem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(insights) { insight in
                    InsightCard(insight: insight)
                }
                if insights.isEmpty {
                    ContentUnavailableView(
                        "Not enough data yet",
                        systemImage: "sparkles",
                        description: Text("Log a few more focus sessions and we'll surface patterns.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(PadTheme.pad)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Insight types

    struct Insight: Identifiable {
        let id: String
        let kind: Kind
        let headline: String
        let body: String
        enum Kind {
            case positive, neutral, attention
            var color: Color {
                switch self {
                case .positive:  return FocusColors.goalGreen
                case .neutral:   return FocusColors.focusRed
                case .attention: return .orange
                }
            }
            var icon: String {
                switch self {
                case .positive:  return "checkmark.seal.fill"
                case .neutral:   return "info.circle.fill"
                case .attention: return "lightbulb.fill"
                }
            }
        }
    }

    private var insights: [Insight] {
        var out: [Insight] = []

        out.append(contentsOf: bestDayOfWeekInsight())
        out.append(contentsOf: peakHourInsight())
        out.append(contentsOf: weekOverWeekInsight())
        out.append(contentsOf: consistencyInsight())
        out.append(contentsOf: problemMixInsight())
        out.append(contentsOf: pacingInsight())
        out.append(contentsOf: breakInsight())

        return out
    }

    // MARK: - Insight builders

    /// Which weekday do you log the most focus on?
    private func bestDayOfWeekInsight() -> [Insight] {
        let cal = Calendar.current
        let work = sessions.filter { $0.isFocus }
        guard work.count >= 10 else { return [] }
        var byWeekday: [Int: Double] = [:]
        for s in work {
            let wd = cal.component(.weekday, from: s.startTime)
            byWeekday[wd, default: 0] += s.durationMinutes
        }
        guard let best = byWeekday.max(by: { $0.value < $1.value }) else { return [] }
        let name = cal.weekdaySymbols[best.key - 1]
        return [.init(
            id: "bestDay",
            kind: .positive,
            headline: "\(name) is your power day",
            body: "You've logged \(PadStats.fmtMinutes(best.value)) of focus on \(name)s overall — your most of any weekday."
        )]
    }

    /// What hour do you usually start? Used to suggest morning vs evening.
    private func peakHourInsight() -> [Insight] {
        let cal = Calendar.current
        let work = sessions.filter { $0.isFocus }
        guard work.count >= 10 else { return [] }
        var byHour: [Int: Double] = [:]
        for s in work {
            let h = cal.component(.hour, from: s.startTime)
            byHour[h, default: 0] += s.durationMinutes
        }
        guard let best = byHour.max(by: { $0.value < $1.value }) else { return [] }
        let label: String
        switch best.key {
        case 5..<9:   label = "early-morning"
        case 9..<12:  label = "mid-morning"
        case 12..<14: label = "lunchtime"
        case 14..<17: label = "afternoon"
        case 17..<20: label = "evening"
        case 20..<24: label = "late-evening"
        default:      label = "overnight"
        }
        return [.init(
            id: "peakHour",
            kind: .neutral,
            headline: "Your sharpest hour: \(formattedHour(best.key))",
            body: "Across your history, you do your most focused work in the \(label) block. Try guarding that window."
        )]
    }

    /// This week vs last week.
    private func weekOverWeekInsight() -> [Insight] {
        let this = PadStats.weekMinutes(sessions, weeksAgo: 0)
        let last = PadStats.weekMinutes(sessions, weeksAgo: 1)
        guard last > 30 else { return [] }
        let delta = this - last
        let pct = delta / last * 100
        if abs(pct) < 10 {
            return [.init(
                id: "wow-flat",
                kind: .neutral,
                headline: "Steady week",
                body: "About the same focus as last week (\(PadStats.fmtMinutes(this)) vs \(PadStats.fmtMinutes(last)))."
            )]
        }
        if delta > 0 {
            return [.init(
                id: "wow-up",
                kind: .positive,
                headline: "Up \(Int(pct))% vs last week",
                body: "\(PadStats.fmtMinutes(this)) so far this week, up from \(PadStats.fmtMinutes(last)). Momentum."
            )]
        } else {
            return [.init(
                id: "wow-down",
                kind: .attention,
                headline: "Down \(Int(abs(pct)))% vs last week",
                body: "\(PadStats.fmtMinutes(this)) vs \(PadStats.fmtMinutes(last)). Worth checking — what's different?"
            )]
        }
    }

    private func consistencyInsight() -> [Insight] {
        let c7 = PadStats.consistencyScore(sessions, days: 7)
        let c30 = PadStats.consistencyScore(sessions, days: 30)
        guard sessions.count >= 5 else { return [] }
        if c7 >= 0.9 {
            return [.init(
                id: "consistency-high",
                kind: .positive,
                headline: "Hit every day this week",
                body: "You've focused on \(Int(c7 * 7))/7 of the last week. That's the habit working."
            )]
        }
        if c7 < c30 - 0.15 {
            return [.init(
                id: "consistency-dip",
                kind: .attention,
                headline: "Consistency dipped this week",
                body: "Last 7 days: \(Int(c7 * 100))%. Last 30 days: \(Int(c30 * 100))%. Don't break the chain."
            )]
        }
        return []
    }

    private func problemMixInsight() -> [Insight] {
        let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Date())!
        let recent = problems.filter { $0.date >= weekStart }
        guard recent.count >= 5 else { return [] }
        let quant = recent.filter { $0.domain == .quant }.count
        let swe = recent.filter { $0.domain == .swe }.count
        guard quant + swe > 0 else { return [] }
        let quantPct = Double(quant) / Double(quant + swe)
        if quantPct > 0.75 || quantPct < 0.25 {
            let leaning = quantPct > 0.5 ? "Quant" : "SWE"
            let lagging = quantPct > 0.5 ? "SWE" : "Quant"
            return [.init(
                id: "mix",
                kind: .attention,
                headline: "Heavy \(leaning) week",
                body: "\(quant) Quant vs \(swe) SWE in the last 7 days. If you need balance, slot in a few \(lagging) problems."
            )]
        }
        return []
    }

    private func pacingInsight() -> [Insight] {
        guard let date = settings.interviewDate, date > Date() else { return [] }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let weeklyTarget = max(1, settings.quantWeeklyGoal + settings.sweWeeklyGoal)
        let thisWeek = PadStats.problemsThisWeek(problems)
        let pace = Double(thisWeek) / Double(weeklyTarget)
        if pace >= 1.0 {
            return [.init(
                id: "pace-on",
                kind: .positive,
                headline: "On pace for interview",
                body: "\(thisWeek)/\(weeklyTarget) problems this week, with \(days) days to go."
            )]
        }
        if pace < 0.5 {
            let need = max(0, weeklyTarget - thisWeek)
            return [.init(
                id: "pace-off",
                kind: .attention,
                headline: "Behind weekly pace",
                body: "Only \(thisWeek)/\(weeklyTarget) problems this week. Need \(need) more to hit pace. \(days) days to interview."
            )]
        }
        return []
    }

    private func breakInsight() -> [Insight] {
        let cal = Calendar.current
        let breaks = sessions.filter { $0.type.isBreak }
        guard breaks.count >= 5 else { return [] }
        var kindCounts: [BreakKind: Int] = [:]
        for s in breaks {
            for k in (s.breakKinds ?? []) { kindCounts[k, default: 0] += 1 }
        }
        guard let top = kindCounts.max(by: { $0.value < $1.value }) else { return [] }
        let recentWindow = cal.date(byAdding: .day, value: -14, to: Date())!
        let recentBreaks = breaks.filter { $0.startTime >= recentWindow }
        guard !recentBreaks.isEmpty else { return [] }
        let avgBreak = recentBreaks.reduce(0) { $0 + $1.durationMinutes } / Double(recentBreaks.count)
        return [.init(
            id: "breaks",
            kind: .neutral,
            headline: "Mostly \(top.key.displayName.lowercased()) breaks",
            body: "Your most-frequent break kind is \(top.key.displayName). Average break length the last 2 weeks: \(PadStats.fmtMinutes(avgBreak))."
        )]
    }

    private func formattedHour(_ h: Int) -> String {
        let mod = h % 12 == 0 ? 12 : h % 12
        let ampm = h < 12 ? "AM" : "PM"
        return "\(mod) \(ampm)"
    }
}

private struct InsightCard: View {
    let insight: InsightsScreen.Insight
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(insight.kind.color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: insight.kind.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(insight.kind.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.headline)
                    .font(.system(size: 16, weight: .semibold))
                Text(insight.body)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PadTheme.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PadTheme.cardRadius)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
