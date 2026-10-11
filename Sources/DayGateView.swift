import SwiftUI
import FocusCore

enum DayGateState: Equatable {
    case unopened
    case open
    case closed
}

private let inkColor = Color(red: 0.96, green: 0.36, blue: 0.36)

private func longDateString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMMM d"
    return f.string(from: d)
}

private func weekdayString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "EEEE"
    return f.string(from: d).uppercased()
}

private func clockString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mma"
    return f.string(from: d)
}

private func formatHM(_ minutes: Double) -> String {
    let h = Int(minutes) / 60
    let m = Int(minutes) % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

struct DayOpenCoverView: View {
    @ObservedObject var dayStore: DayStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessionStore: SessionStore
    var onReviewYesterday: (() -> Void)? = nil
    let onBegin: () -> Void

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Late night"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Text(greeting)
                .font(.system(size: 11, weight: .medium, design: .serif))
                .italic()
                .foregroundStyle(.tertiary)

            Text(longDateString(Date()))
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundStyle(.primary)
                .padding(.top, 6)

            Text(weekdayString(Date()))
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer(minLength: 20)

            VStack(spacing: 4) {
                Image(systemName: "sunrise")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(inkColor.opacity(0.7))
                Text("The page is still blank.")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Button(action: onBegin) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 12))
                    Text("Begin the day")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .tracking(0.5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(inkColor)
                )
                .shadow(color: inkColor.opacity(0.35), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            if let onReviewYesterday {
                let untracked = sessionStore.untrackedMinutes(on: sessionStore.reviewWindow().from)
                if untracked >= 15 {
                    Button(action: onReviewYesterday) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.badge.questionmark").font(.system(size: 10))
                            Text("\(Int(untracked) / 60)h \(Int(untracked) % 60)m untracked yesterday · fill in")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                }
            }

            Spacer(minLength: 22)

            footer
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var footer: some View {
        let streak = sessionStore.currentStreak
        if streak > 0 {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9))
                Text("\(streak)-day streak — keep it alive")
                    .font(.system(size: 10, design: .serif))
                    .italic()
            }
            .foregroundStyle(.orange.opacity(0.85))
        } else {
            Text("Press return to open.")
                .font(.system(size: 9, design: .serif))
                .italic()
                .foregroundStyle(.tertiary)
        }
    }
}

struct DayClosedCoverView: View {
    @ObservedObject var dayStore: DayStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var settings: AppSettings
    let onReopen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Text("The day is closed")
                .font(.system(size: 11, weight: .medium, design: .serif))
                .italic()
                .foregroundStyle(.tertiary)

            Text(longDateString(Date()))
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(.primary)
                .padding(.top, 6)

            if let r = dayStore.todayRecord,
               let start = r.dayStart,
               let end = r.dayEnd {
                Text("\(clockString(start)) – \(clockString(end))")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Spacer(minLength: 18)

            statsRow
                .padding(.horizontal, 8)

            Spacer(minLength: 18)

            VStack(spacing: 4) {
                Image(systemName: "moon.stars")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.indigo.opacity(0.55))
                Text(closingLine)
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 20)

            Button(action: onReopen) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                    Text("Reopen the day")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassChip()
            }
            .buttonStyle(.plain)

            Spacer(minLength: 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var closingLine: String {
        let goalHit = sessionStore.todayWorkMinutes / 60.0 >= Double(settings.dailyGoal)
        let any = sessionStore.todaySessionCount > 0
        if goalHit { return "Goal met. Rest well." }
        if any     { return "Work was done. Rest." }
        return "A quiet page. Tomorrow opens fresh."
    }

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(
                value: formatHM(sessionStore.todayWorkMinutes),
                label: "Focus"
            )
            divider
            statCell(
                value: "\(sessionStore.todaySessionCount)",
                label: "Sessions"
            )
            divider
            statCell(
                value: "\(sessionStore.currentStreak)d",
                label: "Streak",
                tint: sessionStore.currentStreak > 0 ? .orange : nil
            )
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 0.5, height: 28)
    }

    private func statCell(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(tint ?? .primary)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
