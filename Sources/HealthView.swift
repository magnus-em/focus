import SwiftUI
import Charts

struct HealthView: View {
    @ObservedObject var store: HealthStore
    @ObservedObject var sessionStore: SessionStore

    @AppStorage("healthTracker") private var tracker: HealthTracker = .fap
    @State private var backdateKind: HealthKind = .fap
    @State private var justLogged: UUID?
    @State private var showBackdate = false
    @State private var backdate = Date()

    private let accent = Color(red: 0.62, green: 0.48, blue: 0.95)

    private var weeks: [HealthWeek] { store.weeks(tracker, count: 12, sessionStore: sessionStore) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $tracker) {
                    ForEach(HealthTracker.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                logCard
                statsRow
                chartCard
                weeksCard
                recentCard
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
        }
        .onAppear { store.refresh() }
    }

    // MARK: - Log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label(tracker.displayName.uppercased())
                Spacer()
                Text(lastText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(tracker.kinds) { kind in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { justLogged = store.log(kind) }
                        let id = justLogged
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            if justLogged == id { withAnimation { justLogged = nil } }
                        }
                    } label: {
                        Label(tracker.kinds.count == 1 ? "Log now" : kind.displayName, systemImage: "plus")
                            .font(.system(size: tracker.kinds.count == 1 ? 13 : 11, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.85)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    backdate = Date()
                    backdateKind = tracker.kinds.first ?? .fap
                    showBackdate = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 13))
                        .frame(width: 36, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Log at an earlier time")
                .popover(isPresented: $showBackdate, arrowEdge: .bottom) { backdatePopover }
            }

            if let id = justLogged {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Logged").foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        store.delete(id: id)
                        withAnimation { justLogged = nil }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                }
                .font(.system(size: 11, weight: .medium))
                .transition(.opacity)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    private var backdatePopover: some View {
        VStack(spacing: 10) {
            if tracker.kinds.count > 1 {
                Picker("", selection: $backdateKind) {
                    ForEach(tracker.kinds) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            DatePicker("", selection: $backdate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.graphical)
            Button("Log at this time") {
                store.log(backdateKind, at: backdate)
                showBackdate = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var lastText: String {
        guard let days = store.daysSinceLast(tracker) else { return "Nothing logged yet" }
        switch days {
        case 0: return "Last: today"
        case 1: return "Last: yesterday"
        default: return "Last: \(days) days ago"
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        let w = weeks
        let thisWeek = w.last?.total ?? 0
        let lastWeek = w.dropLast().last?.total ?? 0
        let prior = w.dropLast().suffix(8)
        let avg = prior.isEmpty ? 0 : Double(prior.map(\.total).reduce(0, +)) / Double(prior.count)
        let unit = tracker.unit
        return HStack(spacing: 8) {
            stat("\(thisWeek)\(unit)", "this week")
            stat("\(lastWeek)\(unit)", "last week")
            stat(unit.isEmpty ? String(format: "%.1f", avg) : "\(Int(avg.rounded()))\(unit)", "8-wk avg")
            stat("\(store.longestGapDays(tracker))d", "longest gap")
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(caption).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 8)
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(tracker.unit.isEmpty ? "PER WEEK · 12 WEEKS" : "MG PER WEEK · 12 WEEKS")
            Chart(weeks) { w in
                BarMark(
                    x: .value("Week", w.start, unit: .weekOfYear),
                    y: .value("Total", w.total)
                )
                .foregroundStyle(accent.gradient)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 8))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 8))
                }
            }
            .frame(height: 110)
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Weeks vs focus

    private var weeksCard: some View {
        let w = Array(weeks.suffix(8).reversed())
        let maxCount = max(1, w.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("WEEK")
                Spacer()
                label("FOCUS")
            }
            ForEach(w) { week in
                HStack(spacing: 8) {
                    Text(week.start, format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent.opacity(0.7))
                            .frame(width: max(2, geo.size.width * CGFloat(week.total) / CGFloat(maxCount)))
                            .opacity(week.total == 0 ? 0.25 : 1)
                    }
                    .frame(height: 8)
                    Text("\(week.total)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                    Text(String(format: "%.1fh", week.focusHours))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            ForEach([onOffInsight, focusInsight].compactMap { $0 }, id: \.self) { insight in
                Text(insight)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    /// Splits completed weeks at the median count and compares average focus
    /// hours — the "does this track with procrastination?" question.
    private var focusInsight: String? {
        let done = weeks.dropLast().filter { $0.focusHours > 0 }
        guard done.count >= 4 else { return nil }
        let sorted = done.map(\.total).sorted()
        let median = sorted[sorted.count / 2]
        let heavy = done.filter { $0.total > median }
        let light = done.filter { $0.total <= median }
        guard !heavy.isEmpty, !light.isEmpty else { return nil }
        let avg: ([HealthWeek]) -> Double = { $0.map(\.focusHours).reduce(0, +) / Double($0.count) }
        return String(format: "Weeks with more than %d%@: %.1fh focus on average, vs %.1fh in the rest.",
                      median, tracker.unit, avg(heavy), avg(light))
    }

    private var onOffInsight: String? {
        guard tracker == .adderall, let r = store.focusOnVsOff(tracker, sessionStore: sessionStore) else { return nil }
        return String(format: "Dose days: %.1fh focus on average (%d days), vs %.1fh on days off (%d days).",
                      r.on, r.onDays, r.off, r.offDays)
    }

    // MARK: - Recent

    private var recentCard: some View {
        let recent = Array(store.events(tracker).prefix(12))
        return VStack(alignment: .leading, spacing: 6) {
            label("RECENT")
            if recent.isEmpty {
                Text("Tap Log now each time. Patterns show up after a few weeks.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(recent) { e in
                HStack {
                    Text(e.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    if tracker.kinds.count > 1 {
                        Text(e.kind.displayName).foregroundStyle(accent)
                    }
                    Spacer()
                    Text(e.date, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    Button {
                        store.delete(id: e.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Delete")
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}
