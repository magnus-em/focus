import SwiftUI
import FocusCore

struct CommitmentReviewView: View {
    @ObservedObject var dayStore: DayStore
    let day: DayRecord
    @Binding var isShowing: Bool

    private let green = Color(red: 0.27, green: 0.75, blue: 0.45)
    private let red = Color(red: 0.96, green: 0.36, blue: 0.36)

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                    Text(headerTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(promptLabel)
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(.secondary)
                            Text("\u{201C}\(day.commitmentText ?? "")\u{201D}")
                                .font(.system(size: 13).italic())
                                .foregroundStyle(.primary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(9)
                        }

                        Text("Be honest — accountability only works if it's true.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(18)
                }

                Divider()

                HStack(spacing: 8) {
                    Button { answer(true) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                            Text("Yes, I did it")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(green)
                        .cornerRadius(9)
                    }
                    .buttonStyle(.plainHit)

                    Button { answer(false) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark")
                            Text("No")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(red)
                        .cornerRadius(9)
                    }
                    .buttonStyle(.plainHit)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func answer(_ b: Bool) {
        dayStore.setFulfillment(b, forDayID: day.id)
        isShowing = false
    }

    private var headerTitle: String {
        Calendar.current.isDateInToday(day.calendarDay)
            ? "How did today go?"
            : "How did \(relativeDay) go?"
    }

    private var headerSubtitle: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return f.string(from: day.calendarDay)
    }

    private var promptLabel: String {
        Calendar.current.isDateInToday(day.calendarDay)
            ? "DID YOU DO WHAT YOU SET OUT TO DO TODAY?"
            : "DID YOU DO WHAT YOU SET OUT TO DO?"
    }

    private var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInYesterday(day.calendarDay) { return "yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: day.calendarDay).lowercased()
    }
}
