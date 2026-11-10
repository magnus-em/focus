import SwiftUI
import Charts
import FocusCore

private let checkInAccent = Color(red: 0.62, green: 0.48, blue: 0.95)

@MainActor
final class AdderallCheckInWindowController: NSObject, NSWindowDelegate {
    static let shared = AdderallCheckInWindowController()
    private var window: NSWindow?
    weak var health: HealthStore?
    weak var sessions: SessionStore?

    func open(day: Date = Date(), trends: Bool = false) {
        guard let health, let sessions else { return }
        window?.close()
        let view = AdderallCheckInWindow(store: .shared, health: health, sessions: sessions,
                                         day: Calendar.current.startOfDay(for: day), page: trends ? 1 : 0) { [weak self] in
            self?.window?.close()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Adderall check-in"
        w.setContentSize(NSSize(width: 520, height: 780))
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct AdderallCheckInWindow: View {
    @ObservedObject var store: AdderallCheckInStore
    @ObservedObject var health: HealthStore
    let sessions: SessionStore
    @State var day: Date
    @State var page: Int
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("Check in").tag(0)
                Text("How it's going").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260).padding(.vertical, 12)
            ScrollView {
                Group {
                    if page == 0 {
                        AdderallCheckInForm(day: $day, existing: store.checkIn(on: day),
                                            doses: health.doses(on: day, through: .distantFuture), saveError: store.saveError) { c in
                            if store.save(c) { page = 1 }
                        }
                        .id(day)
                    } else {
                        AdderallTrendsView(checkIns: store.all, focusHours: { focusHours(sessions, $0) },
                                           reminderOn: $store.reminderOn, reminderMinutes: $store.reminderMinutes)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(minWidth: 460, minHeight: 500)
    }
}

func focusHours(_ sessions: SessionStore, _ day: Date) -> Double {
    let cal = Calendar.current
    let start = cal.startOfDay(for: day)
    guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return 0 }
    return sessions.workMinutes(since: start, until: end) / 60
}

// MARK: - Form

struct AdderallCheckInForm: View {
    @Binding var day: Date
    let doses: [HealthEvent]
    let saveError: String?
    let onSave: (AdderallCheckIn) -> Void
    @State private var c: AdderallCheckIn

    init(day: Binding<Date>, existing: AdderallCheckIn?, doses: [HealthEvent], saveError: String?, onSave: @escaping (AdderallCheckIn) -> Void) {
        _day = day
        self.doses = doses
        self.saveError = saveError
        self.onSave = onSave
        let tookDose = !doses.isEmpty
        var fresh = AdderallCheckIn(day: AdderallCheckIn.dayKey(day.wrappedValue), tookDose: tookDose)
        if tookDose {
            fresh.hoursWorked = 0
            fresh.comedown = 3
            fresh.worthIt = 6
        }
        _c = State(initialValue: existing ?? fresh)
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            card {
                Toggle(isOn: $c.tookDose) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Took Adderall \(isToday ? "today" : "that day")").font(.system(size: 13, weight: .medium))
                        Text(doses.isEmpty ? "No dose logged. Off days are the baseline everything else is compared with."
                                           : doses.map { "\($0.kind.displayName) at \($0.date.formatted(date: .omitted, time: .shortened))" }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: c.tookDose) { _, took in
                    if took {
                        if c.hoursWorked == nil { c.hoursWorked = 0 }
                        if c.comedown == nil { c.comedown = 3 }
                        if c.worthIt == nil { c.worthIt = 6 }
                    }
                }
            }
            card {
                section("How the day felt")
                slider(.focus, int: $c.focus)
                slider(.mood, int: $c.mood)
                slider(.anxiety, int: $c.anxiety)
                slider(.appetite, int: $c.appetite)
                slider(.sleep, int: $c.sleep)
            }
            if c.tookDose {
                card {
                    section("The medication")
                    slider(.hoursWorked, double: Binding(get: { c.hoursWorked ?? 0 }, set: { c.hoursWorked = $0 }))
                    slider(.comedown, int: Binding(get: { c.comedown ?? 0 }, set: { c.comedown = $0 }))
                    slider(.worthIt, int: Binding(get: { c.worthIt ?? 0 }, set: { c.worthIt = $0 }))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Side effects").font(.system(size: 13, weight: .medium))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(AdderallCheckIn.sideEffects, id: \.self) { effect in
                                let on = c.effects.contains(effect)
                                Button {
                                    if on { c.effects.removeAll { $0 == effect } } else { c.effects.append(effect) }
                                } label: {
                                    Text(effect).font(.system(size: 12, weight: on ? .semibold : .regular))
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(Capsule().fill(on ? checkInAccent.opacity(0.85) : Color.secondary.opacity(0.12)))
                                        .foregroundStyle(on ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            card {
                section("Note")
                TextField("Optional: dose timing, what you ate, how you slept", text: $c.note, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            if let saveError { Text("Couldn't save: \(saveError)").font(.system(size: 12)).foregroundStyle(.orange) }
            Button { onSave(c) } label: { Text("Save check-in").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(checkInAccent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13))
    }

    private var header: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                .accessibilityLabel("Previous day")
            Spacer()
            VStack(spacing: 2) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 15, weight: .semibold))
                Text("Review the starting values and adjust them to match your day.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                .disabled(isToday).accessibilityLabel("Next day")
        }
        .buttonStyle(.plain)
    }

    private func move(_ by: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: by, to: day) { day = d }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentCard()
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold))
    }

    private func slider(_ m: CheckInMetric, int: Binding<Int>) -> some View {
        slider(m, double: Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0.rounded()) }))
    }

    private func slider(_ m: CheckInMetric, double: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(m == .hoursWorked ? String(format: "%g h", double.wrappedValue) : "\(Int(double.wrappedValue))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            Text(m.question).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Slider(value: double, in: 0...m.maxValue, step: m == .hoursWorked ? 0.5 : 1)
                .tint(checkInAccent)
                .accessibilityLabel(m.title)
                .accessibilityValue(m == .hoursWorked ? "\(double.wrappedValue) hours" : "\(Int(double.wrappedValue)) of 10")
            HStack {
                Text(m.low)
                Spacer()
                Text(m.high)
            }
            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
        }
    }
}

// MARK: - Trends

struct AdderallTrendsView: View {
    let checkIns: [String: AdderallCheckIn]
    let focusHours: (Date) -> Double
    @Binding var reminderOn: Bool
    @Binding var reminderMinutes: Int
    var end: Date = Date()

    @AppStorage("adderallTrendsDays") private var days = 30
    @AppStorage("adderallTrendsMetric") private var metric: CheckInMetric = .focus

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        let dose: Bool
        var id: Date { date }
    }

    private var summary: CheckInSummary { CheckInSummary.make(checkIns, days: days, end: end) }

    private var windowDays: [Date] {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: end)
        return (0..<days).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: endDay) }
    }

    private func points(_ m: CheckInMetric) -> [Point] {
        windowDays.compactMap { d in
            guard let c = checkIns[AdderallCheckIn.dayKey(d)], let v = m.value(c) else { return nil }
            return Point(date: d, value: v, dose: c.tookDose)
        }
    }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $days) {
                Text("Week").tag(7)
                Text("Month").tag(30)
                Text("3 months").tag(90)
            }
            .pickerStyle(.segmented).labelsHidden()

            if s.checkIns == 0 {
                Text("No check-ins in this stretch yet. After a week of evenings this shows how dose days compare with off days.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentCard()
            } else {
                headline(s)
                chartCard
                compareCard(s)
                if !s.effects.isEmpty { effectsCard(s) }
            }
            reminderCard
        }
        .font(.system(size: 13))
    }

    private func headline(_ s: CheckInSummary) -> some View {
        let worth = s.splits.first { $0.metric == .worthIt }
        let hours = s.splits.first { $0.metric == .hoursWorked }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(s.checkIns) check-ins · \(s.doseDays) dose days · \(s.checkIns - s.doseDays) off days")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            HStack(spacing: 8) {
                stat(worth?.dose.map { String(format: "%.1f", $0) } ?? "—", "worth it (of 10)", delta: delta(worth))
                stat(hours?.dose.map { String(format: "%.1f h", $0) } ?? "—", "felt it working", delta: delta(hours))
                stat(gap(s, .focus), "focus, dose vs off", delta: nil)
            }
        }
    }

    private func gap(_ s: CheckInSummary, _ m: CheckInMetric) -> String {
        guard let split = s.splits.first(where: { $0.metric == m }), let d = split.dose, let o = split.off else { return "—" }
        return String(format: "%+.1f", d - o)
    }

    private func delta(_ split: CheckInSummary.Split?) -> String? {
        guard let split, let d = split.dose, let p = split.previous, abs(d - p) >= 0.25 else { return nil }
        return String(format: "%+.1f vs before", d - p)
    }

    private func stat(_ value: String, _ caption: String, delta: String?) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(caption).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
            Text(delta ?? " ").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).contentCard(cornerRadius: 14)
    }

    private var chartCard: some View {
        let pts = points(metric)
        let dosePts = pts.filter(\.dose)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Day by day").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(CheckInMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text(metric == .sleep ? "Each point is the night before that day." : metric.question)
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Chart {
                ForEach(dosePts) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value), series: .value("s", "dose"))
                        .foregroundStyle(checkInAccent.opacity(0.45))
                        .interpolationMethod(.monotone)
                }
                ForEach(pts) { p in
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value))
                        .symbol(p.dose ? .circle : .square)
                        .symbolSize(days > 30 ? 22 : 40)
                        .foregroundStyle(p.dose ? checkInAccent : Color.secondary)
                }
            }
            .chartYScale(domain: 0...metric.maxValue)
            .chartXScale(domain: (windowDays.first ?? end)...(Calendar.current.date(byAdding: .day, value: 1, to: windowDays.last ?? end) ?? end))
            .chartLegend(.hidden)
            .frame(height: 170)
            HStack(spacing: 14) {
                Label("Dose day", systemImage: "circle.fill").foregroundStyle(checkInAccent)
                if !metric.doseOnly { Label("Off day", systemImage: "square.fill").foregroundStyle(Color.secondary) }
            }
            .font(.system(size: 11)).labelStyle(.titleAndIcon)
        }
        .padding(16).contentCard()
    }

    private func compareCard(_ s: CheckInSummary) -> some View {
        let doseDays = windowDays.filter { checkIns[AdderallCheckIn.dayKey($0)]?.tookDose == true }
        let offDays = windowDays.filter { checkIns[AdderallCheckIn.dayKey($0)]?.tookDose == false }
        func avgHours(_ list: [Date]) -> String {
            list.isEmpty ? "—" : String(format: "%.1f h", list.map(focusHours).reduce(0, +) / Double(list.count))
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Dose days vs off days").font(.system(size: 15, weight: .semibold))
            Text("Your reported averages, not proof of a medication effect. Sleep counts the night after each day.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Dose").gridColumnAlignment(.trailing)
                    Text("Off").gridColumnAlignment(.trailing)
                    Text("Dose, before").gridColumnAlignment(.trailing)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText)
                ForEach(s.splits, id: \.metric) { split in
                    GridRow {
                        Text(split.metric == .sleep ? "Sleep that night" : split.metric.title)
                        Text(fmt(split.dose, split.metric)).fontWeight(.semibold)
                            .foregroundStyle(tone(split))
                        Text(split.metric.doseOnly ? "" : fmt(split.off, split.metric))
                        Text(fmt(split.previous, split.metric)).foregroundStyle(Color.secondaryText)
                    }
                    .monospacedDigit()
                }
                Divider().gridCellColumns(4)
                GridRow {
                    Text("Focus tracked")
                    Text(avgHours(doseDays)).fontWeight(.semibold)
                    Text(avgHours(offDays))
                    Text("")
                }
                .monospacedDigit()
            }
            Text("Before = the \(days == 7 ? "week" : "\(days) days") before this one.")
                .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentCard()
    }

    /// Dose average colored only when it clearly differs from off days (±1).
    private func tone(_ split: CheckInSummary.Split) -> Color {
        guard let d = split.dose, let o = split.off, abs(d - o) >= 1 else { return .primary }
        let better = split.metric.higherIsWorse ? d < o : d > o
        return better ? .green : .orange
    }

    private func fmt(_ v: Double?, _ m: CheckInMetric) -> String {
        guard let v else { return "—" }
        return m == .hoursWorked ? String(format: "%.1f h", v) : String(format: "%.1f", v)
    }

    private func effectsCard(_ s: CheckInSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Side effects").font(.system(size: 15, weight: .semibold))
            ForEach(s.effects, id: \.name) { e in
                HStack {
                    Text(e.name)
                    Spacer()
                    Text("\(e.days) of \(s.doseDays) dose days").monospacedDigit().foregroundStyle(Color.secondaryText)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentCard()
    }

    private var reminderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Evening reminder", isOn: $reminderOn).toggleStyle(.switch)
            if reminderOn {
                DatePicker("Remind at", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); reminderMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 30) }
                ), displayedComponents: .hourAndMinute)
                Text("Only on days you haven't checked in yet.").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentCard()
    }
}



// MARK: - Popover card

/// Top of the Health tab's Adderall page: today's check-in status and a way in.
struct AdderallCheckInCard: View {
    @ObservedObject var store: AdderallCheckInStore
    var open: (Date, Bool) -> Void

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let done = store.checkIn(on: today)
        let missedYesterday = store.checkIn(on: yesterday) == nil && !store.all.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily check-in").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Trends") { open(today, true) }.buttonStyle(.plain).foregroundStyle(checkInAccent)
            }
            if let done {
                Text("Done for today · focus \(done.focus), mood \(done.mood)\(done.worthIt.map { ", worth it \($0)" } ?? "")")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                Button("Edit today's answers") { open(today, false) }.buttonStyle(.bordered)
            } else {
                Text("How the medication treated you today: focus, mood, anxiety, appetite, sleep, how long it lasted.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button { open(today, false) } label: { Text("Check in for today").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(checkInAccent)
            }
            if missedYesterday {
                Button("Missed yesterday? Check in for it") { open(yesterday, false) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(checkInAccent)
            }
        }
        .padding(16).contentCard()
    }
}
