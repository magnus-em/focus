import SwiftUI
import SwiftData
import FocusCore

/// Apple Fitness / habit-tracker style overview. Three rings, momentum cards,
/// streak, weekly summary, focus by tag, and recent activity preview.
struct DashboardScreen: View {
    @EnvironmentObject var settings: PadSettings

    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]
    @Query(sort: \StoredProblem.date, order: .reverse) private var problems: [StoredProblem]
    @Query(sort: \StoredHomework.date, order: .reverse) private var homework: [StoredHomework]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                greetingHeader
                personalBestBanner
                ringsCard
                momentumCards
                homeworkCard
                streakCard
                weeklySummaryCard
                focusByTagCard
                interviewCountdownCard
                recentActivityCard
            }
            .padding(PadTheme.pad)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Personal best detection

    private var personalBest: PersonalBest? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let workSessions = sessions.filter { $0.isFocus }
        guard !workSessions.isEmpty else { return nil }

        // Best day in history.
        let byDay = workSessions.reduce(into: [Date: Double]()) {
            $0[cal.startOfDay(for: $1.startTime), default: 0] += $1.durationMinutes
        }
        let todayMin = byDay[today] ?? 0
        let priorBest = byDay.filter { $0.key < today }.values.max() ?? 0
        if todayMin > priorBest, todayMin >= 60 {
            return PersonalBest(
                title: "New personal best!",
                detail: "\(PadStats.fmtMinutes(todayMin)) of focus today — your most ever.",
                icon: "trophy.fill",
                color: .yellow
            )
        }

        // Streak record.
        let streakNow = PadStats.currentStreak(sessions)
        if streakNow >= 7, streakNow == PadStats.bestStreak(sessions) {
            return PersonalBest(
                title: "Longest streak yet",
                detail: "\(streakNow) days in a row. Don't stop.",
                icon: "flame.fill",
                color: .orange
            )
        }

        // First > 4h day milestone.
        if todayMin >= 240, priorBest < 240 {
            return PersonalBest(
                title: "First 4-hour day",
                detail: "Crossed the 4-hour mark today.",
                icon: "sun.max.fill",
                color: .orange
            )
        }

        // Goal-hit celebration.
        let goalMin = Double(settings.dailyGoalHours) * 60
        if todayMin >= goalMin, goalMin > 0 {
            return PersonalBest(
                title: "Goal hit ✓",
                detail: "\(PadStats.fmtMinutes(todayMin)) of \(settings.dailyGoalHours)h goal complete. Bonus rounds.",
                icon: "checkmark.circle.fill",
                color: FocusColors.goalGreen
            )
        }

        return nil
    }

    private struct PersonalBest {
        let title: String
        let detail: String
        let icon: String
        let color: Color
    }

    @ViewBuilder
    private var personalBestBanner: some View {
        if let pb = personalBest {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(pb.color.opacity(0.18)).frame(width: 44, height: 44)
                    Image(systemName: pb.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(pb.color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pb.title).font(.system(size: 15, weight: .semibold))
                    Text(pb.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: PadTheme.cardRadius, style: .continuous)
                    .fill(LinearGradient(colors: [pb.color.opacity(0.18), pb.color.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PadTheme.cardRadius)
                    .stroke(pb.color.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Helpers

    private var todayMinutes: Double {
        PadStats.workMinutes(sessions, on: Date())
    }
    private var todayProblems: Int {
        PadStats.problemsToday(problems)
    }
    private var consistency7d: Double {
        PadStats.consistencyScore(sessions, days: 7)
    }
    private var streak: Int {
        PadStats.currentStreak(sessions)
    }
    private var bestStreak: Int {
        PadStats.bestStreak(sessions)
    }

    // MARK: - Sections

    private var greetingHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.title3).foregroundStyle(.secondary)
                Text(headlineText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }
            Spacer()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Up late"
        }
    }

    private var headlineText: String {
        let h = todayMinutes / 60
        if h < 0.1 { return "Let's get started." }
        if h < 1 { return String(format: "%.1fh in. Keep going.", h) }
        let g = Double(settings.dailyGoalHours)
        if h >= g { return "Goal hit. Bonus rounds." }
        return String(format: "%.1fh of %.0fh today.", h, g)
    }

    private var ringsCard: some View {
        let goalMin = max(1, Double(settings.dailyGoalHours) * 60)
        let dailyProblemTarget = max(1, settings.quantGoal + settings.sweGoal)
        let consistencyTarget = 7

        let rings: [RingsView.Ring] = [
            .init(id: "focus",
                  progress: todayMinutes / goalMin,
                  color: PadTheme.focusRing,
                  label: "FOCUS",
                  value: PadStats.fmtMinutes(todayMinutes),
                  goal: "\(settings.dailyGoalHours)h"),
            .init(id: "problems",
                  progress: Double(todayProblems) / Double(dailyProblemTarget),
                  color: PadTheme.problemsRing,
                  label: "PROBLEMS",
                  value: "\(todayProblems)",
                  goal: "\(dailyProblemTarget)"),
            .init(id: "consistency",
                  progress: consistency7d,
                  color: PadTheme.consistencyRing,
                  label: "CONSISTENCY",
                  value: "\(Int(consistency7d * 7))",
                  goal: "\(consistencyTarget) days"),
        ]

        return PadCard(padding: 20) {
            HStack(alignment: .center, spacing: 20) {
                RingsView(rings: rings, lineWidth: 18, spacing: 4)
                    .frame(width: 200, height: 200)
                RingsLegend(rings: rings)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var momentumCards: some View {
        let today = todayMinutes
        let yesterday = PadStats.workMinutes(sessions, on: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let delta = today - yesterday
        let deltaText: String = {
            if abs(delta) < 5 { return "≈ yesterday" }
            let sign = delta > 0 ? "▲" : "▼"
            return "\(sign) \(PadStats.fmtMinutes(abs(delta))) vs yesterday"
        }()

        return HStack(spacing: 10) {
            PadMetric(value: PadStats.fmtMinutes(today),
                      label: "TODAY", icon: "flame.fill",
                      tint: FocusColors.focusRed,
                      trailing: deltaText)
            PadMetric(value: "\(streak)",
                      label: "STREAK", icon: "bolt.fill",
                      tint: .orange,
                      trailing: bestStreak > 0 ? "best \(bestStreak)" : nil)
        }
    }

    private var homeworkCard: some View {
        let cal = Calendar.current
        let todayCount = homework.filter { cal.isDateInToday($0.date) }.count
        let goal = settings.homeworkDailyGoal
        let pct: Double = goal > 0 ? min(1.0, Double(todayCount) / Double(goal)) : 0
        let purple = Color(red: 0.62, green: 0.45, blue: 0.92)
        let hit = goal > 0 && todayCount >= goal

        // Last 14 days mini bars
        let today = cal.startOfDay(for: Date())
        let days: [(Date, Int)] = (0..<14).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            let n = homework.filter { cal.isDate($0.date, inSameDayAs: d) }.count
            return (d, n)
        }
        let maxN = max(goal, days.map(\.1).max() ?? 0, 1)

        return PadCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    PadSectionHeader(title: "HOMEWORK")
                    Spacer()
                    if goal > 0 {
                        Text("\(todayCount)/\(goal) today")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(hit ? Color.green : purple)
                    } else {
                        Text("\(todayCount) today")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(purple)
                    }
                }
                if goal > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(purple.opacity(0.12))
                            Capsule()
                                .fill(hit ? Color.green : purple)
                                .frame(width: g.size.width * CGFloat(pct))
                                .animation(.spring(response: 0.5), value: pct)
                        }
                    }
                    .frame(height: 8)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, item in
                        let (date, n) = item
                        let pctBar = Double(n) / Double(maxN)
                        let dayHit = goal > 0 && n >= goal
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(n == 0 ? Color.gray.opacity(0.18)
                                      : dayHit ? Color.green : purple.opacity(0.7))
                                .frame(height: max(4, CGFloat(pctBar) * 60))
                                .frame(maxWidth: .infinity)
                            Text(dayLetter(date))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 76)
            }
        }
    }

    private var streakCard: some View {
        let last14 = PadStats.lastNDaysMinutes(sessions, days: 14)
        let goalMin = max(1, Double(settings.dailyGoalHours) * 60)
        return PadCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PadSectionHeader(title: "LAST 14 DAYS")
                    Spacer()
                    Text(PadStats.fmtMinutes(last14.map(\.1).reduce(0, +)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(last14, id: \.0) { (day, mins) in
                        let pct = min(mins / goalMin, 1.5)
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barFill(pct))
                                .frame(height: max(4, CGFloat(pct) * 80))
                                .frame(maxWidth: .infinity)
                            Text(dayLetter(day))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    private func barFill(_ pct: Double) -> Color {
        if pct >= 1.0 { return FocusColors.goalGreen }
        if pct >= 0.5 { return FocusColors.focusRed }
        if pct > 0    { return FocusColors.focusRed.opacity(0.5) }
        return Color.gray.opacity(0.18)
    }

    private func dayLetter(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEEE"
        return f.string(from: d)
    }

    private var weeklySummaryCard: some View {
        let thisWeek = PadStats.weekMinutes(sessions, weeksAgo: 0)
        let lastWeek = PadStats.weekMinutes(sessions, weeksAgo: 1)
        let delta = thisWeek - lastWeek
        let pct = lastWeek > 0 ? (delta / lastWeek) * 100 : 0
        let best = PadStats.bestWeekMinutes(sessions)

        return PadCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PadSectionHeader(title: "THIS WEEK")
                    Spacer()
                    Text("best \(PadStats.fmtHoursOnly(best))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(PadStats.fmtMinutes(thisWeek))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    if lastWeek > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            Text(String(format: "%.0f%%", abs(pct)))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                    }
                    Spacer()
                }
                Text("vs \(PadStats.fmtMinutes(lastWeek)) last week")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var focusByTagCard: some View {
        let byTag = PadStats.byTag(sessions, days: 7)
        let total = max(1.0, byTag.reduce(0) { $0 + $1.minutes })
        return PadCard {
            VStack(alignment: .leading, spacing: 12) {
                PadSectionHeader(title: "FOCUS · 7 DAYS")
                if byTag.isEmpty {
                    Text("No focus sessions in the last week.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(byTag, id: \.tag) { row in
                                Rectangle()
                                    .fill(tagColor(row.tag))
                                    .frame(width: max(2, geo.size.width * (row.minutes / total)))
                            }
                        }
                    }
                    .frame(height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(byTag.prefix(5), id: \.tag) { row in
                            HStack(spacing: 8) {
                                Circle().fill(tagColor(row.tag)).frame(width: 8, height: 8)
                                Text(row.tag).font(.callout)
                                Spacer()
                                Text(PadStats.fmtMinutes(row.minutes))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tagColor(_ tag: String) -> Color {
        // Stable hash → hue.
        var h: UInt64 = 5381
        for ch in tag.unicodeScalars { h = (h &* 33) &+ UInt64(ch.value) }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    @ViewBuilder
    private var interviewCountdownCard: some View {
        if let date = settings.interviewDate, date > Date() {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            let goalTotal = max(1, settings.quantGoal + settings.sweGoal) * max(1, days)
            let solved = problems.count
            let pct = min(1.0, Double(solved) / Double(goalTotal))
            PadCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        PadSectionHeader(title: "INTERVIEW")
                        Spacer()
                        Text(date, style: .date)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(days)")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(FocusColors.focusRed)
                        Text("days to go")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if goalTotal > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15))
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(FocusColors.focusRed)
                                    .frame(width: max(8, geo.size.width * pct))
                            }
                        }
                        .frame(height: 8)
                        Text("\(solved) problems · pacing for \(goalTotal) by interview")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var recentActivityCard: some View {
        let recent = sessions.prefix(5)
        return PadCard {
            VStack(alignment: .leading, spacing: 0) {
                PadSectionHeader(title: "RECENT ACTIVITY").padding(.bottom, 8)
                if recent.isEmpty {
                    Text("No sessions yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, s in
                        if idx > 0 { Divider().padding(.leading, 30) }
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(s.type == .work ? FocusColors.focusRed : FocusColors.breakBlue)
                                .frame(width: 3, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rowTitle(s))
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                Text("\(s.startTime, format: .dateTime.hour().minute()) · \(PadStats.fmtMinutes(s.durationMinutes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func rowTitle(_ s: StoredWorkSession) -> String {
        if s.type == .work { return s.label ?? "Focus" }
        let kinds = (s.breakKinds ?? []).map(\.displayName).joined(separator: ", ")
        return kinds.isEmpty ? "Break" : kinds
    }
}
