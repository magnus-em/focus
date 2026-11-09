import AppKit
import FocusCore
import SwiftUI

/// A change the Day page asks the Dashboard to make to the log.
enum DayEdit: Equatable {
    /// Log [start, end) as a category ("Break" for a break).
    case log(start: Date, end: Date, label: String)
    /// Leave [start, end) untracked.
    case clear(start: Date, end: Date)
}

/// Focus minutes for one day of the two-week strip.
struct DayStripDay: Identifiable, Equatable {
    let date: Date
    let minutes: Double
    var id: Date { date }
}

/// The Day page as a calendar: your log on an hour grid with what the screen
/// saw beside it and your classes next to that. Drag over any stretch to log
/// it as something, drag a block's edge to move it, click a block to change
/// it. Review steps through the stretches where the log and the screen or the
/// calendar disagree; a light day says why next to its numbers.
struct DayCalendarPage: View {
    @ObservedObject var model: DayStoryModel
    let day: Date
    let focusMinutes: Double
    let goalHours: Double
    let categories: [String]
    let why: DayWhy.Report?
    let strip: [DayStripDay]
    let fixByTyping: AnyView?
    let scrollTo: (String) -> Void
    let selectDay: (Date) -> Void
    let edit: ([DayEdit], String) -> Void
    let openCoach: () -> Void

    enum Selection: Equatable {
        case block(DayStory.Tracked)
        case range(Date, Date)
        case fix(DayStory.Fix)
    }

    private struct Drag: Equatable {
        enum Mode: Equatable {
            case range(anchor: Date)
            case top(DayStory.Tracked)
            case bottom(DayStory.Tracked)
        }
        var mode: Mode
        var current: Date
    }

    @State private var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: DayStoryPage.dismissedKey) ?? [])
    @State private var selection: Selection?
    @State private var review: [DayStory.Fix] = []
    @State private var reviewIndex = 0
    @State private var drag: Drag?
    @State private var showNight = false
    @State private var highlight: DayWhy.Reason?
    @State private var editStart = Date()
    @State private var editEnd = Date()

    private static let hourHeight: CGFloat = 64
    private static let gutter: CGFloat = 52
    private static let screenWidth: CGFloat = 12
    private static let eventWidth: CGFloat = 150

    private var calendar: Calendar { .current }
    private var dayStart: Date { calendar.startOfDay(for: day) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart)! }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private var limit: Date { min(dayEnd, Date()) }
    private var fixes: [DayStory.Fix] { (model.story?.fixes ?? []).filter { !dismissed.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    facts
                    Spacer(minLength: 0)
                    dayStrip
                }
                VStack(alignment: .leading, spacing: 20) {
                    facts
                    dayStrip
                }
            }
            if let why, why.light { whyCard(why) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    mainColumn.frame(minWidth: 520, maxWidth: .infinity, alignment: .leading)
                    side.frame(width: 300)
                }
                VStack(alignment: .leading, spacing: 24) {
                    mainColumn
                    side
                }
            }
        }
        .onChange(of: day) { _, _ in
            selection = nil
            review = []
            highlight = nil
            showNight = false
        }
        .onChange(of: selection) { _, s in
            if case .block(let t) = s {
                editStart = t.start
                editEnd = t.end
            }
        }
    }

    // MARK: Top

    private var facts: some View {
        HStack(alignment: .top, spacing: 32) {
            fact("Focus time", durationText(minutes: focusMinutes), goalLine,
                 color: focusMinutes >= goalHours * 60 ? .good : .primary)
            if let c = model.story?.courses.first {
                fact("Studied", c.code, studiedLine(c), color: .primary)
            }
            if model.story != nil {
                if fixes.isEmpty {
                    fact("Log check", "Looks right", "Your log agrees with your calendar and screen", color: .good)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log check").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                        Button(action: startReview) {
                            HStack(spacing: 8) {
                                Text(fixes.count == 1 ? "1 to check" : "\(fixes.count) to check")
                                    .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Color.attention)
                                Text("Review").font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                                    .background(Capsule().fill(Color.primary))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Step through them: Return takes the suggestion, Delete keeps your log, → skips")
                        Text("Where your log and your screen or calendar disagree")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
    }

    private var goalLine: String {
        let goal = goalHours * 60
        if focusMinutes >= goal { return "On your timer · your \(goalHours.formatted())h goal is met" }
        return "On your timer · \(durationText(minutes: goal - focusMinutes)) short of your \(goalHours.formatted())h goal"
    }

    private func studiedLine(_ c: DayStory.Course) -> String {
        var parts: [String] = []
        if let t = c.topics.first { parts.append(t) }
        if let p = c.practiceShare, c.observations >= 5 { parts.append("\(Int((p * 100).rounded()))% hands-on") }
        return parts.isEmpty ? "Seen on your screen" : parts.joined(separator: " · ")
    }

    private func fact(_ label: String, _ value: String, _ caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(caption).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    /// The last two weeks of focus, one bar a day: the way back to "last Wednesday".
    private var dayStrip: some View {
        let goal = goalHours * 60
        let top = max(goal, strip.map(\.minutes).max() ?? 0, 60)
        let barHeight: CGFloat = 40
        return VStack(alignment: .leading, spacing: 6) {
            Text("Focus, last 14 days").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(strip) { d in
                    let selected = calendar.isDate(d.date, inSameDayAs: day)
                    Button { selectDay(d.date) } label: {
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottom) {
                                Capsule().fill(Color.primary.opacity(0.06)).frame(width: 10, height: barHeight)
                                Capsule().fill(d.minutes >= goal ? Color.good : Color.primary.opacity(selected ? 0.75 : 0.4))
                                    .frame(width: 10, height: max(3, barHeight * CGFloat(min(d.minutes / top, 1))))
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Color.secondaryText.opacity(0.6)).frame(width: 16, height: 1)
                                    .offset(y: -barHeight * CGFloat(goal / top))
                            }
                            Text(d.date.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            Text(d.date.formatted(.dateTime.day()))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.secondaryText)
                        }
                        .frame(width: 26).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(d.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(durationText(minutes: d.minutes)) of focus")
                    .accessibilityLabel("\(d.date.formatted(.dateTime.weekday(.wide).month(.wide).day())), \(durationText(minutes: d.minutes)) of focus")
                }
            }
        }
    }

    // MARK: Why

    private func whyCard(_ why: DayWhy.Report) -> some View {
        let title = why.focusMinutes < 1 ? "Why no focus" : "Why only \(durationText(minutes: why.focusMinutes)) of focus"
        let subtitle = why.usualMinutes.map {
            "Compared with the \(why.comparedDays) tracked days before it, when your median was \(durationText(minutes: $0)). From your timer and screen."
        } ?? "Too few tracked days before it to compare, so this is where the time went."
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title, subtitle: subtitle)
            if why.reasons.isEmpty {
                Text("Nothing in your log stands out against your usual days.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            ForEach(why.reasons) { r in
                if r.ranges.isEmpty {
                    reasonRow(r)
                } else {
                    Button { show(r) } label: { reasonRow(r) }
                        .buttonStyle(.plain)
                        .help("Mark it on the calendar")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    private func reasonRow(_ r: DayWhy.Reason) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(r)).font(.system(size: 12))
                .foregroundStyle(r.category.map(categoryColor) ?? Color.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 13, weight: .semibold))
                if let d = r.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !r.ranges.isEmpty {
                Text(highlight?.id == r.id ? "Shown below" : "Show")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func icon(_ r: DayWhy.Reason) -> String {
        switch r.kind {
        case .lateStart: return "sunrise"
        case .sleep: return "bed.double.fill"
        case .category: return r.category.map(categoryIcon) ?? "circle"
        case .untracked: return "questionmark.circle"
        case .fragmented: return "square.split.1x2"
        case .drift: return "eye"
        }
    }

    private func show(_ r: DayWhy.Reason) {
        guard let first = r.ranges.map(\.start).min() else { return }
        highlight = highlight?.id == r.id ? nil : r
        guard highlight != nil else { return }
        if first < visibleRange.start { showNight = true }
        DispatchQueue.main.async { scrollTo(rowID(for: first)) }
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let fixByTyping {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Fix by typing", subtitle: "“9:12 to 9:40 was leisure”, or drag over any stretch of the calendar below")
                    fixByTyping
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Your day", subtitle: "Drag over a stretch to log it as something else, drag a block's edge to move it, click a block to change it.")
                if let night { nightRow(night) }
                columnHeaders
                calendarGrid
            }
        }
    }

    private var night: DayStory.Tracked? {
        guard let s = model.lanes.tracked.filter({ $0.label == "Sleep" && $0.start <= dayStart.addingTimeInterval(60) })
            .max(by: { $0.end < $1.end }), s.end.timeIntervalSince(dayStart) >= 3 * 3600 else { return nil }
        return s
    }

    private func nightRow(_ s: DayStory.Tracked) -> some View {
        let end = min(s.end, limit)
        return Button { showNight.toggle() } label: {
            HStack(spacing: 10) {
                Circle().fill(categoryColor("Sleep")).frame(width: 8, height: 8)
                Text("Sleep").font(.system(size: 13, weight: .semibold))
                Text("\(clock(max(s.start, dayStart))) – \(clock(end)) · \(durationText(minutes: end.timeIntervalSince(max(s.start, dayStart)) / 60))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
                Spacer()
                Text(showNight ? "Hide the night" : "Show the night")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                Image(systemName: showNight ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            Text("Your log").frame(maxWidth: .infinity, alignment: .leading)
            Text("Screen").fixedSize().frame(width: Self.screenWidth + 40, alignment: .trailing)
            if !model.lanes.events.isEmpty {
                Text("Calendar").frame(width: Self.eventWidth, alignment: .leading).padding(.leading, 12)
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText)
    }

    // MARK: Calendar geometry

    private var visibleRange: (start: Date, end: Date) {
        func floorHour(_ d: Date) -> Date { calendar.dateInterval(of: .hour, for: d)?.start ?? d }
        func ceilHour(_ d: Date) -> Date { let f = floorHour(d); return f == d ? d : f.addingTimeInterval(3600) }
        let lanes = model.lanes
        let clippedStarts = (lanes.tracked.map(\.start) + lanes.screen.map(\.start) + lanes.events.map(\.start))
            .map { max($0, dayStart) }.filter { $0 < dayEnd }
        let clippedEnds = (lanes.tracked.map(\.end) + lanes.screen.map(\.end) + lanes.events.map(\.end))
            .map { min($0, dayEnd) }.filter { $0 > dayStart }
        var start: Date
        if let night, !showNight {
            start = floorHour(min(night.end, limit))
        } else if showNight {
            start = dayStart
        } else {
            start = clippedStarts.min().map(floorHour) ?? dayStart.addingTimeInterval(8 * 3600)
        }
        var end = isToday ? ceilHour(Date().addingTimeInterval(20 * 60)) : ceilHour(clippedEnds.max() ?? start)
        end = min(max(end, start.addingTimeInterval(3 * 3600)), dayEnd)
        start = min(start, end.addingTimeInterval(-3600))
        return (start, end)
    }

    private var hours: [Date] {
        let r = visibleRange
        return stride(from: 0, to: r.end.timeIntervalSince(r.start), by: 3600).map { r.start.addingTimeInterval($0) }
    }

    private func rowID(for d: Date) -> String {
        let h = calendar.dateInterval(of: .hour, for: max(d, visibleRange.start))?.start ?? d
        return "cal-\(Int(h.timeIntervalSince1970))"
    }

    private func y(_ d: Date) -> CGFloat {
        CGFloat(d.timeIntervalSince(visibleRange.start) / 3600) * Self.hourHeight
    }

    private func date(at y: CGFloat) -> Date {
        let r = visibleRange
        let d = r.start.addingTimeInterval(Double(y / Self.hourHeight) * 3600)
        return min(max(d, r.start), min(r.end, limit))
    }

    /// Five-minute steps, pulled onto a nearby block edge or now.
    private func snap(_ d: Date) -> Date {
        let edges = model.lanes.tracked.flatMap { [$0.start, $0.end] } + (isToday ? [Date()] : [])
        if let e = edges.min(by: { abs($0.timeIntervalSince(d)) < abs($1.timeIntervalSince(d)) }),
           abs(e.timeIntervalSince(d)) <= 150 {
            return min(e, limit)
        }
        return min(Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 300).rounded() * 300), limit)
    }

    private var visibleTracked: [DayStory.Tracked] {
        let r = visibleRange
        return model.lanes.tracked.filter { $0.end > r.start && $0.start < r.end }.sorted { $0.start < $1.start }
    }

    /// Untracked stretches of 5 minutes or more between your first and last block (and up to now today).
    private var gaps: [(Date, Date)] {
        let t = model.lanes.tracked.sorted { $0.start < $1.start }
        var merged: [(Date, Date)] = []
        for x in t {
            if let l = merged.last, x.start <= l.1 { merged[merged.count - 1].1 = max(l.1, x.end) } else { merged.append((x.start, x.end)) }
        }
        var out: [(Date, Date)] = []
        for (a, b) in zip(merged, merged.dropFirst()) where b.0.timeIntervalSince(a.1) >= 300 { out.append((a.1, b.0)) }
        if isToday, let last = merged.last, !t.contains(where: \.running), limit.timeIntervalSince(last.1) >= 300 {
            out.append((last.1, limit))
        }
        return out.compactMap { g in
            let a = max(g.0, dayStart), b = min(g.1, dayEnd)
            return b > a ? (a, b) : nil
        }
    }

    // MARK: Calendar

    private var calendarGrid: some View {
        let r = visibleRange
        let height = CGFloat(r.end.timeIntervalSince(r.start) / 3600) * Self.hourHeight
        let events = model.lanes.events
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { h in
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.hourHeight)
                    .id("cal-\(Int(h.timeIntervalSince1970))")
                }
            }
            .padding(.leading, Self.gutter)
            HStack(alignment: .top, spacing: 0) {
                hourLabels.frame(width: Self.gutter)
                GeometryReader { geo in
                    logColumn(width: geo.size.width)
                }
                .frame(height: height)
                screenStrip.frame(width: Self.screenWidth, height: height).padding(.leading, 8)
                if !events.isEmpty {
                    eventColumn(events).frame(width: Self.eventWidth, height: height).padding(.leading, 12)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your day as a calendar")
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(hours, id: \.self) { h in
                Text(hourText(h))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8)
                    .offset(y: -7)
                    .frame(height: Self.hourHeight, alignment: .top)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isToday, Date() < visibleRange.end {
                Text("now").font(.system(size: 11, weight: .semibold)).padding(.trailing, 8)
                    .offset(y: y(Date()) - 7)
            }
        }
    }

    private func hourText(_ h: Date) -> String {
        let hour = calendar.component(.hour, from: h)
        if hour == 0 { return "12 AM" }
        if hour == 12 { return "Noon" }
        return hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
    }

    private func logColumn(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.001)
            if let h = highlight {
                ForEach(Array(h.ranges.enumerated()), id: \.offset) { _, range in
                    let a = max(range.start, visibleRange.start), b = min(range.end, visibleRange.end)
                    if b > a {
                        Rectangle().fill(Color.accentColor.opacity(0.14))
                            .frame(width: width, height: y(b) - y(a)).offset(y: y(a))
                    }
                }
            }
            ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in gapView(g, width: width) }
            ForEach(visibleTracked, id: \.start) { t in blockView(t, width: width) }
            ForEach(fixes.filter { !isUntracked($0) }) { f in fixMarker(f, width: width) }
            if let drag { dragPreview(drag, width: width) }
            if isToday, Date() > visibleRange.start, Date() < visibleRange.end {
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: width + Self.screenWidth + 8, height: 1.5)
                    .offset(y: y(Date()))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(logGesture)
        .onContinuousHover { phase in
            if case .active(let p) = phase, drag == nil, edgeHit(p.y) != nil {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .popover(isPresented: Binding(get: { selection != nil }, set: { if !$0 { closePopover() } }),
                 attachmentAnchor: .rect(.rect(anchorRect(width: width))), arrowEdge: .trailing) {
            popover.frame(width: 320).padding(16)
        }
    }

    private func anchorRect(width: CGFloat) -> CGRect {
        let r = visibleRange
        let range: (Date, Date)
        switch selection {
        case .block(let t): range = (t.start, t.end)
        case .range(let a, let b): range = (a, b)
        case .fix(let f): range = (f.start, f.end)
        case nil: range = (r.start, r.start)
        }
        let a = max(range.0, r.start), b = max(min(range.1, r.end), a)
        return CGRect(x: 0, y: y(a), width: width, height: max(y(b) - y(a), 4))
    }

    private func blockView(_ t: DayStory.Tracked, width: CGFloat) -> some View {
        let r = visibleRange
        let a = max(t.start, r.start), b = min(t.end, r.end)
        let h = max(y(b) - y(a) - 2, 2)
        let color = categoryColor(t.label)
        let selected = selection == .block(t)
        let lines = h >= 40 ? seen(t.start, t.end, title: t.label).prefix(max(1, Int((h - 26) / 32))).map(\.text) : []
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.18))
            Rectangle().fill(color).frame(width: 3)
            if h >= 16 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(t.label).font(.system(size: 13, weight: .semibold))
                        Text("\(clock(t.start)) – \(t.running ? "now" : clock(t.end)) · \(durationText(minutes: t.end.timeIntervalSince(t.start) / 60))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(DayStory.twelveHour(line)).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 10).padding(.trailing, 8).padding(.top, h >= 24 ? 4 : 0)
                .frame(maxHeight: h, alignment: h >= 24 ? .topLeading : .leading)
                .clipped()
            }
        }
        .frame(width: width - 4, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color, lineWidth: selected ? 2 : 0)
        }
        .offset(y: y(a) + 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func gapView(_ g: (Date, Date), width: CGFloat) -> some View {
        let r = visibleRange
        let a = max(g.0, r.start), b = min(g.1, r.end)
        let h = max(y(b) - y(a) - 2, 2)
        let flagged = fixes.contains { isUntracked($0) && $0.start <= g.0.addingTimeInterval(60) && $0.end >= g.1.addingTimeInterval(-60) }
        let seenAs = DayStory.dominantScreen(model.lanes.screen, from: g.0, to: g.1)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(flagged ? Color.attention : Color.primary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if h >= 16 {
                HStack(spacing: 6) {
                    Text("Nothing logged").font(.system(size: 12, weight: .semibold))
                    Text("\(clock(g.0)) – \(clock(g.1))\(seenAs.map { " · the screen showed \($0)" } ?? "") · click to fill")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
                .padding(.horizontal, 10).frame(maxHeight: min(h, 24))
            }
        }
        .frame(width: width - 4, height: h)
        .offset(y: y(a) + 1)
        .allowsHitTesting(false)
        .opacity(a < b ? 1 : 0)
    }

    private func fixMarker(_ f: DayStory.Fix, width: CGFloat) -> some View {
        let r = visibleRange
        let a = max(f.start, r.start), b = min(f.end, r.end)
        return ZStack(alignment: .top) {
            Capsule().fill(Color.attention).frame(width: 4)
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color.attention)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .offset(y: -6)
        }
        .frame(width: 14, height: max(y(b) - y(a), 6))
        .offset(x: width - 18, y: y(a))
        .opacity(b > a ? 1 : 0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dragPreview(_ d: Drag, width: CGFloat) -> some View {
        switch d.mode {
        case .range(let anchor):
            let a = min(anchor, d.current), b = max(anchor, d.current)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.22))
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                Text("\(clock(a)) – \(clock(b)) · \(durationText(minutes: b.timeIntervalSince(a) / 60))")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .padding(6)
            }
            .frame(width: width - 4, height: max(y(b) - y(a), 2))
            .offset(y: y(a))
            .allowsHitTesting(false)
        case .top(let t), .bottom(let t):
            let isTop = d.mode == .top(t)
            let a = isTop ? min(d.current, t.end.addingTimeInterval(-300)) : t.start
            let b = isTop ? t.end : max(d.current, t.start.addingTimeInterval(300))
            ZStack(alignment: isTop ? .topLeading : .bottomLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(categoryColor(t.label), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                Text(clock(isTop ? a : b)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .padding(6)
            }
            .frame(width: width - 4, height: max(y(min(b, visibleRange.end)) - y(max(a, visibleRange.start)), 2))
            .offset(y: y(max(a, visibleRange.start)))
            .allowsHitTesting(false)
        }
    }

    private var screenStrip: some View {
        let r = visibleRange
        let screen = model.lanes.screen
        return Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                     with: .color(Color.primary.opacity(0.05)))
            for s in screen {
                guard let c = s.category else { continue }
                let a = max(s.start, r.start), b = min(s.end, r.end)
                guard b > a else { continue }
                let rect = CGRect(x: 0, y: y(a), width: size.width, height: max(1, y(b) - y(a)))
                ctx.fill(Path(rect), with: .color(categoryColor(c).opacity(s.uncertain ? 0.4 : 1)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help("What your Mac's screen showed, labeled by category")
    }

    private func eventColumn(_ events: [DayStory.CalendarEvent]) -> some View {
        let r = visibleRange
        return ZStack(alignment: .topLeading) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                let a = max(e.start, r.start), b = min(e.end, r.end)
                if b > a {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        if y(b) - y(a) >= 40 {
                            Text("\(clock(e.start)) – \(clock(e.end))").font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(width: Self.eventWidth, height: max(y(b) - y(a) - 2, 2), alignment: .topLeading)
                    .clipped()
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
                    .offset(y: y(a) + 1)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Gestures

    private var logGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    let start = date(at: v.startLocation.y)
                    if let hit = edgeHit(v.startLocation.y) {
                        drag = Drag(mode: hit.top ? .top(hit.block) : .bottom(hit.block), current: start)
                    } else {
                        drag = Drag(mode: .range(anchor: snap(start)), current: snap(start))
                    }
                }
                drag?.current = snap(date(at: v.location.y))
            }
            .onEnded { v in
                let d = drag
                drag = nil
                guard let d, abs(v.translation.height) >= 4 else { return tap(at: v.location.y) }
                finish(d)
            }
    }

    /// A saved block's top or bottom edge within 5 points; on a shared edge,
    /// above it moves the earlier block's end, below it the later block's start.
    private func edgeHit(_ py: CGFloat) -> (block: DayStory.Tracked, top: Bool)? {
        let r = visibleRange
        var hits: [(block: DayStory.Tracked, top: Bool, edge: CGFloat)] = []
        for t in visibleTracked where !t.running {
            let top = y(max(t.start, r.start)), bottom = y(min(t.end, r.end))
            guard bottom - top >= 10 else { continue }
            if t.start >= r.start, abs(py - top) <= 5 { hits.append((t, true, top)) }
            if t.end <= min(r.end, limit), abs(py - bottom) <= 5 { hits.append((t, false, bottom)) }
        }
        let inside = hits.filter { $0.top ? py >= $0.edge : py <= $0.edge }
        return (inside.isEmpty ? hits : inside).min { abs(py - $0.edge) < abs(py - $1.edge) }.map { ($0.block, $0.top) }
    }

    private func tap(at py: CGFloat) {
        let d = date(at: py)
        if let t = visibleTracked.last(where: { $0.start <= d && d < $0.end }) {
            selection = selection == .block(t) ? nil : .block(t)
        } else if let g = gaps.first(where: { $0.0 <= d && d < $0.1 }) {
            selection = .range(g.0, g.1)
        } else {
            selection = nil
        }
        review = []
    }

    private func finish(_ d: Drag) {
        switch d.mode {
        case .range(let anchor):
            let a = min(anchor, d.current), b = max(anchor, d.current)
            guard b.timeIntervalSince(a) >= 60 else { return }
            review = []
            selection = .range(a, b)
        case .top(let t):
            let s1 = min(d.current, t.end.addingTimeInterval(-300))
            if s1 < t.start {
                edit([.log(start: s1, end: t.start, label: t.label)], "\(t.label) now starts at \(clock(s1)).")
            } else if s1 > t.start {
                edit([.clear(start: t.start, end: s1)], "\(t.label) now starts at \(clock(s1)).")
            }
        case .bottom(let t):
            let e1 = min(max(d.current, t.start.addingTimeInterval(300)), limit)
            if e1 > t.end {
                edit([.log(start: t.end, end: e1, label: t.label)], "\(t.label) now ends at \(clock(e1)).")
            } else if e1 < t.end {
                edit([.clear(start: e1, end: t.end)], "\(t.label) now ends at \(clock(e1)).")
            }
        }
    }

    // MARK: Popovers

    @ViewBuilder
    private var popover: some View {
        switch selection {
        case .block(let t): blockPanel(t)
        case .range(let a, let b): rangePanel(a, b)
        case .fix(let f): fixPanel(f)
        case nil: EmptyView()
        }
    }

    private func blockPanel(_ t: DayStory.Tracked) -> some View {
        let color = categoryColor(t.label)
        let blockFixes = fixes.filter { !isUntracked($0) && $0.end > t.start && $0.start < t.end }
        let moments = seen(t.start, t.end, title: t.label)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(t.label).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if t.running { Text("Running").font(.system(size: 11, weight: .semibold)).foregroundStyle(color) }
                }
                Text("\(clock(t.start)) – \(t.running ? "now" : clock(t.end)) · \(durationText(minutes: t.end.timeIntervalSince(t.start) / 60))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.secondaryText)
            }
            ForEach(blockFixes) { f in
                VStack(alignment: .leading, spacing: 8) {
                    Label(message(f), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.primary)
                        .labelStyle(AttentionLabelStyle())
                    HStack(spacing: 8) {
                        if let s = f.suggestion {
                            pill("Make it \(s)", prominent: true) { apply(f, s) }
                        }
                        pill("Keep \(t.label)", prominent: false) { keep(f) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.attention.opacity(0.1)))
            }
            seenList(moments)
            VStack(alignment: .leading, spacing: 6) {
                Text(t.running ? "Switch what's running to" : "Change to").font(.system(size: 12, weight: .semibold))
                categoryChips(except: t.label) { label in
                    edit([.log(start: t.start, end: t.running ? Date() : t.end, label: label)],
                         "Logged \(clock(t.start))–\(t.running ? "now" : clock(t.end)) as \(label).")
                    selection = nil
                }
            }
            if !t.running {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Times").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        DatePicker("From", selection: $editStart, displayedComponents: .hourAndMinute).labelsHidden()
                        Text("to").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        DatePicker("To", selection: $editEnd, displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        pill("Save", prominent: false) { saveTimes(t) }
                            .disabled(editStart == t.start && editEnd == t.end)
                    }
                }
                Button(role: .destructive) {
                    edit([.clear(start: t.start, end: t.end)], "Removed \(clock(t.start))–\(clock(t.end)) from your log.")
                    selection = nil
                } label: {
                    Text("Remove from log").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.red)
            }
        }
    }

    private func saveTimes(_ t: DayStory.Tracked) {
        let s1 = min(editStart, limit), e1 = min(editEnd, limit)
        guard e1.timeIntervalSince(s1) >= 60 else { return }
        var edits: [DayEdit] = []
        if s1 < t.start { edits.append(.log(start: s1, end: t.start, label: t.label)) }
        if s1 > t.start { edits.append(.clear(start: t.start, end: min(s1, t.end))) }
        if e1 > t.end { edits.append(.log(start: t.end, end: e1, label: t.label)) }
        if e1 < t.end { edits.append(.clear(start: max(e1, t.start), end: t.end)) }
        guard !edits.isEmpty else { return }
        edit(edits, "\(t.label) is now \(clock(s1))–\(clock(e1)).")
        selection = nil
    }

    private func rangePanel(_ a: Date, _ b: Date) -> some View {
        let logged = Array(Set(model.lanes.tracked.filter { $0.end > a && $0.start < b }.map(\.label))).sorted()
        let screen = DayStory.dominantScreen(model.lanes.screen, from: a, to: b)
        let suggestion = screen.flatMap { s in categories.contains(s) && !(logged == [s]) ? s : nil }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(clock(a)) – \(clock(b))").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Text(durationText(minutes: b.timeIntervalSince(a) / 60)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            VStack(alignment: .leading, spacing: 3) {
                row("Your log", logged.isEmpty ? "nothing" : logged.joined(separator: ", "))
                row("Screen", screen ?? "nothing clear")
            }
            seenList(seen(a, b, title: nil))
            VStack(alignment: .leading, spacing: 6) {
                Text("Log it as").font(.system(size: 12, weight: .semibold))
                if let suggestion {
                    pill("\(suggestion), as the screen showed", prominent: true) { logRange(a, b, suggestion) }
                        .keyboardShortcut(.defaultAction)
                }
                categoryChips(except: suggestion) { logRange(a, b, $0) }
            }
            HStack {
                if !logged.isEmpty {
                    Button("Clear this stretch") {
                        edit([.clear(start: a, end: b)], "Cleared \(clock(a))–\(clock(b)).")
                        selection = nil
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Cancel") { selection = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            }
        }
    }

    private func logRange(_ a: Date, _ b: Date, _ label: String) {
        edit([.log(start: a, end: b, label: label)], "Logged \(clock(a))–\(clock(b)) as \(label).")
        selection = nil
    }

    private func fixPanel(_ f: DayStory.Fix) -> some View {
        let moments = seen(f.start, f.end, title: nil)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(reviewIndex + 1) of \(review.count)").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Done") { closePopover() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(clock(f.start)) – \(f.running ? "now" : clock(f.end))").font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text(durationText(minutes: f.minutes)).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            VStack(alignment: .leading, spacing: 3) {
                row("Your log", f.tracked ?? "nothing")
                switch f.kind {
                case .calendar(let event): row("Calendar", event)
                case .screenDiffers(let seen): row("Screen", seen)
                case .untracked(let seen): row("Screen", seen ?? DayStory.dominantScreen(model.lanes.screen, from: f.start, to: f.end) ?? "nothing clear")
                }
            }
            seenList(moments)
            HStack(spacing: 8) {
                if let s = f.suggestion {
                    pill("Make it \(s)", prominent: true) { apply(f, s); advance() }
                        .keyboardShortcut(.defaultAction)
                }
                Menu {
                    ForEach(categories, id: \.self) { c in Button(c) { apply(f, c); advance() } }
                } label: {
                    Text(f.suggestion == nil ? "Log as…" : "Other…").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                pill(f.tracked.map { "Keep \($0)" } ?? "Leave it", prominent: false) { keep(f); advance() }
                    .keyboardShortcut(.delete, modifiers: [])
                Spacer(minLength: 0)
                Button { advance() } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next").accessibilityLabel("Next")
            }
            Text(shortcutLine(f)).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
        }
    }

    private func shortcutLine(_ f: DayStory.Fix) -> String {
        var parts: [String] = []
        if let s = f.suggestion { parts.append("↩ make it \(s)") }
        parts.append("⌫ \(f.tracked.map { "keep \($0)" } ?? "leave it")")
        parts.append("→ next")
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.secondaryText).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 13, weight: .medium))
        }
    }

    @ViewBuilder
    private func seenList(_ moments: [DayStory.Moment]) -> some View {
        if !moments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("What Focus saw").font(.system(size: 12, weight: .semibold))
                ForEach(moments.prefix(4)) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(clock(m.start)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.secondaryText)
                            .frame(width: 58, alignment: .leading)
                        Text(DayStory.twelveHour(m.text)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if moments.count > 4 {
                    Text("and \(moments.count - 4) more").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }

    private func categoryChips(except: String?, pick: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(categories.filter { $0 != except }, id: \.self) { c in
                Button { pick(c) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(categoryColor(c)).frame(width: 7, height: 7)
                        Text(c).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(prominent ? Color.primary : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Review

    private func startReview() {
        review = fixes.sorted { $0.start < $1.start }
        reviewIndex = 0
        guard let first = review.first else { return }
        focusOn(first)
    }

    private func focusOn(_ f: DayStory.Fix) {
        if f.start < visibleRange.start { showNight = true }
        selection = .fix(f)
        DispatchQueue.main.async { scrollTo(rowID(for: f.start)) }
    }

    private func advance() {
        reviewIndex += 1
        if reviewIndex < review.count {
            focusOn(review[reviewIndex])
        } else {
            review = []
            selection = nil
        }
    }

    private func closePopover() {
        selection = nil
        review = []
    }

    private func apply(_ f: DayStory.Fix, _ label: String) {
        edit([.log(start: f.start, end: f.running ? Date() : f.end, label: label)],
             "Logged \(clock(f.start))–\(f.running ? "now" : clock(f.end)) as \(label).")
        if case .block = selection { selection = nil }
    }

    private func keep(_ f: DayStory.Fix) {
        dismissed.insert(f.id)
        UserDefaults.standard.set(Array(dismissed.suffix(400)), forKey: DayStoryPage.dismissedKey)
    }

    private func isUntracked(_ f: DayStory.Fix) -> Bool {
        if case .untracked = f.kind { return true }
        return false
    }

    private func message(_ f: DayStory.Fix) -> String {
        let range = "\(clock(f.start))–\(f.running ? "now" : clock(f.end))"
        switch f.kind {
        case .calendar(let event): return "\(event) was on your calendar \(range)."
        case .untracked(let seen): return seen.map { "Nothing logged \(range); the screen showed \($0)." } ?? "Nothing logged \(range)."
        case .screenDiffers(let seen): return "The screen showed \(seen) \(range)."
        }
    }

    // MARK: Side column

    private var side: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let story = model.story, let headline = story.headline {
                card {
                    Text(story.headlineAsOf.map { "Focus's summary · written \(clock($0))" } ?? "Focus's summary")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                    Text(DayStory.twelveHour(headline)).font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            timeBars
            if let story = model.story {
                ForEach(Array(story.courses.prefix(2).enumerated()), id: \.element.id) { i, c in
                    courseCard(c, first: i == 0, questions: i == 0 && isToday ? story.questions : 0)
                }
                if !story.noticed.isEmpty {
                    card {
                        Text("Focus noticed").font(.system(size: 14, weight: .semibold))
                        ForEach(story.noticed.prefix(3), id: \.self) { n in
                            Text(n).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button(action: openCoach) {
                Label(isToday ? "Ask Focus about today" : "Ask Focus about this day", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Talk this day through with Focus")
        }
    }

    private var timeBars: some View {
        var totals: [String: Double] = [:]
        for t in model.lanes.tracked {
            let m = min(t.end, limit).timeIntervalSince(max(t.start, dayStart)) / 60
            if m > 0 { totals[t.label, default: 0] += m }
        }
        var rows = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value, false) }
        let unlogged = gaps.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) / 60 }
        if unlogged >= 1 { rows.append(("Not logged", unlogged, true)) }
        let top = rows.map(\.1).max() ?? 1
        return card {
            VStack(alignment: .leading, spacing: 2) {
                Text("Where your time went").font(.system(size: 14, weight: .semibold))
                Text("From your timer").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            if rows.isEmpty {
                Text(isToday ? "Nothing tracked yet today." : "Nothing tracked on this day.")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 8) {
                    Text(row.0).font(.system(size: 12)).lineLimit(1).frame(width: 80, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(row.2 ? Color.primary.opacity(0.2) : categoryColor(row.0))
                            .frame(width: max(4, geo.size.width * CGFloat(row.1 / top)), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 16)
                    Text(row.1 < 1 ? "<1m" : durationText(minutes: row.1)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Color.secondaryText).frame(width: 52, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func courseCard(_ c: DayStory.Course, first: Bool, questions: Int) -> some View {
        card {
            if first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What you learned").font(.system(size: 14, weight: .semibold))
                    Text("Topics Focus saw you study, by course").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                }
            }
            Text(c.code).font(.system(size: 13, weight: .semibold)).foregroundStyle(categoryColor(c.category))
            if !c.topics.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(c.topics.prefix(10), id: \.self) { t in
                        Text(t).font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
            }
            if !c.shaky.isEmpty {
                Text("Where you struggled").font(.system(size: 12, weight: .semibold)).padding(.top, 2)
                ForEach(c.shaky.prefix(3), id: \.self) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Color.attention)
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
            }
            if c.observations >= 5 { HowStudiedBar(course: c) }
            if questions > 0 {
                Text(questions == 1 ? "1 question waits for tomorrow morning." : "\(questions) questions wait for tomorrow morning.")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
    }

    // MARK: Helpers

    /// What the coach saw starting inside [a, b), each line once.
    private func seen(_ a: Date, _ b: Date, title: String?) -> [DayStory.Moment] {
        guard let story = model.story else { return [] }
        var out: [DayStory.Moment] = []
        for block in story.blocks {
            for m in block.moments + block.interruptions where m.start >= a.addingTimeInterval(-60) && m.start < b {
                let text = m.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !out.contains(where: { $0.text == text }) else { continue }
                if let title, DayStory.restates(text, title: title) { continue }
                out.append(m)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

/// An amber warning icon beside its text.
private struct AttentionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(Color.attention)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
