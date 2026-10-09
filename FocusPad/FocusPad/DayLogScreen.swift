import SwiftUI
import SwiftData
import FocusCore

/// Per-day timeline + event log. Browse any past day; today shows live.
struct DayLogScreen: View {
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var allSessions: [StoredWorkSession]
    @Query(sort: \StoredProblem.date, order: .reverse) private var allProblems: [StoredProblem]
    @Query(sort: \StoredDayRecord.calendarDay, order: .reverse) private var dayRecords: [StoredDayRecord]

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private var todaySessions: [StoredWorkSession] {
        let cal = Calendar.current
        return allSessions.filter { cal.isDate($0.startTime, inSameDayAs: selectedDay) }
    }

    private var focusMinutes: Double {
        todaySessions.filter { $0.isFocus }.reduce(0) { $0 + $1.durationMinutes }
    }

    private var breakMinutes: Double {
        todaySessions.filter { $0.type.isBreak }.reduce(0) { $0 + $1.durationMinutes }
    }

    private var todayProblems: [StoredProblem] {
        let cal = Calendar.current
        return allProblems.filter { cal.isDate($0.date, inSameDayAs: selectedDay) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                dayHeader
                statCards
                timelineCard
                eventList
            }
            .padding(PadTheme.pad)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Day Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dayHeader: some View {
        HStack {
            Button { shift(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(dayTitle).font(.system(size: 17, weight: .semibold))
                Text(dateSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { shift(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .disabled(Calendar.current.isDateInToday(selectedDay))
            .opacity(Calendar.current.isDateInToday(selectedDay) ? 0.3 : 1)
        }
    }

    private var statCards: some View {
        HStack(spacing: 10) {
            statCard(value: PadStats.fmtMinutes(focusMinutes), label: "Focus",
                     icon: "timer", color: FocusColors.focusRed)
            statCard(value: PadStats.fmtMinutes(breakMinutes), label: "Break",
                     icon: "cup.and.saucer", color: FocusColors.breakBlue)
            statCard(value: "\(todayProblems.count)", label: "Problems",
                     icon: "checkmark.circle", color: FocusColors.goalGreen)
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: PadTheme.smallCardRadius).fill(color.opacity(0.10))
        )
    }

    private var timelineCard: some View {
        let focus = todaySessions.filter { $0.type == .work }
        let breaks = todaySessions.filter { $0.type.isBreak }
        return PadCard {
            VStack(alignment: .leading, spacing: 10) {
                PadSectionHeader(title: "TIMELINE")
                if focus.isEmpty && breaks.isEmpty {
                    Text("No sessions this day.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    iPadTimelineCanvas(day: selectedDay, focus: focus, breaks: breaks)
                }
            }
        }
    }

    private var eventList: some View {
        PadCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PadSectionHeader(title: "EVENTS")
                    .padding(.horizontal, PadTheme.pad)
                    .padding(.top, PadTheme.pad)
                    .padding(.bottom, 6)

                let events = makeEvents()
                if events.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .padding(PadTheme.pad)
                } else {
                    ForEach(Array(events.enumerated()), id: \.element.id) { (idx, e) in
                        if idx > 0 { Divider().padding(.leading, 70) }
                        EventRow(event: e)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private struct UIEvent: Identifiable {
        let id: String
        let time: Date
        let kind: Kind
        enum Kind {
            case focus(StoredWorkSession)
            case breakSession(StoredWorkSession)
            case problem(StoredProblem)
        }
    }

    private func makeEvents() -> [UIEvent] {
        let f = todaySessions.filter { $0.type == .work }.map {
            UIEvent(id: $0.id.uuidString, time: $0.startTime, kind: .focus($0))
        }
        let b = todaySessions.filter { $0.type.isBreak }.map {
            UIEvent(id: $0.id.uuidString + "-b", time: $0.startTime, kind: .breakSession($0))
        }
        let p = todayProblems.map {
            UIEvent(id: $0.id.uuidString, time: $0.date, kind: .problem($0))
        }
        return (f + b + p).sorted { $0.time > $1.time }
    }

    private struct EventRow: View {
        let event: UIEvent
        var body: some View {
            HStack(spacing: 12) {
                Text(time).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).frame(width: 50, alignment: .trailing)
                switch event.kind {
                case .focus(let s):
                    Rectangle().fill(FocusColors.focusRed).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label ?? "Focus").font(.system(size: 14, weight: .medium))
                        Text(PadStats.fmtMinutes(s.durationMinutes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .breakSession(let s):
                    Rectangle().fill(FocusColors.breakBlue).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        let kinds = (s.breakKinds ?? []).map(\.displayName).joined(separator: ", ")
                        Text(kinds.isEmpty ? "Break" : kinds)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(FocusColors.breakBlue)
                        Text(PadStats.fmtMinutes(s.durationMinutes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .problem(let p):
                    Circle().fill(p.confidence.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title.isEmpty ? "Problem" : p.title)
                            .font(.system(size: 14)).lineLimit(1)
                        Text("\(p.domain.rawValue) · \(p.difficulty.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, PadTheme.pad).padding(.vertical, 10)
        }

        private var time: String {
            let f = DateFormatter(); f.dateFormat = "h:mm"
            return f.string(from: event.time)
        }
    }

    private func shift(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDay) {
            let today = Calendar.current.startOfDay(for: Date())
            selectedDay = min(Calendar.current.startOfDay(for: next), today)
        }
    }

    private var dayTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(selectedDay) { return "Today" }
        if cal.isDateInYesterday(selectedDay) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: selectedDay)
    }

    private var dateSubtitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM d"
        return f.string(from: selectedDay)
    }
}

// MARK: - Timeline canvas

struct iPadTimelineCanvas: View {
    let day: Date
    let focus: [StoredWorkSession]
    let breaks: [StoredWorkSession]

    private struct Block: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
        let label: String
        let color: Color
    }

    private struct LaidOut: Identifiable {
        let id = UUID()
        let block: Block
        let lane: Int
        let totalLanes: Int
    }

    private var blocks: [Block] {
        let all = focus.map { Block(
            start: $0.startTime,
            end: $0.startTime.addingTimeInterval($0.durationMinutes * 60),
            label: $0.label ?? "Focus",
            color: FocusColors.focusRed
        )} + breaks.map { s in
            let kinds = (s.breakKinds ?? []).map(\.displayName).joined(separator: ", ")
            return Block(
                start: s.startTime,
                end: s.startTime.addingTimeInterval(s.durationMinutes * 60),
                label: kinds.isEmpty ? "Break" : kinds,
                color: FocusColors.breakBlue
            )
        }
        return all.sorted { $0.start < $1.start }
    }

    /// Lane assignment for overlapping blocks — see DashboardView for full
    /// explanation. Renders overlapping sessions side-by-side in columns.
    private var laidOut: [LaidOut] {
        let sorted = blocks
        var assignments: [(block: Block, lane: Int)] = []
        var laneEnds: [Date] = []
        for b in sorted {
            var lane = -1
            for (i, e) in laneEnds.enumerated() where e <= b.start {
                lane = i; break
            }
            if lane == -1 {
                lane = laneEnds.count
                laneEnds.append(b.end)
            } else {
                laneEnds[lane] = b.end
            }
            assignments.append((b, lane))
        }
        var result: [LaidOut] = []
        var cluster: [(Block, Int)] = []
        var clusterEnd: Date? = nil
        let flush: ([(Block, Int)]) -> Void = { items in
            let total = (items.map(\.1).max() ?? 0) + 1
            for (blk, lane) in items {
                result.append(LaidOut(block: blk, lane: lane, totalLanes: total))
            }
        }
        for item in assignments {
            if let ce = clusterEnd, item.block.start < ce {
                cluster.append(item)
                clusterEnd = max(ce, item.block.end)
            } else {
                if !cluster.isEmpty { flush(cluster) }
                cluster = [item]
                clusterEnd = item.block.end
            }
        }
        if !cluster.isEmpty { flush(cluster) }
        return result
    }

    private var hourRange: (start: Int, end: Int) {
        let cal = Calendar.current
        guard let first = blocks.map(\.start).min(),
              let last = blocks.map(\.end).max() else { return (8, 18) }
        var s = cal.component(.hour, from: first)
        var e = cal.component(.hour, from: last)
        if cal.component(.minute, from: last) > 0 { e += 1 }
        s = max(0, s - 1); e = min(24, e + 1)
        if e - s < 8 { e = min(24, s + 8) }
        return (s, e)
    }

    var body: some View {
        let range = hourRange
        let totalHours = range.end - range.start
        let rowHeight: CGFloat = 28
        let height = CGFloat(totalHours) * rowHeight

        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(range.start..<range.end, id: \.self) { h in
                    Text(hourLabel(h))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, height: rowHeight, alignment: .trailing)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.secondary.opacity(0.05)).cornerRadius(6)
                    ForEach(laidOut) { item in
                        blockView(item, range: range, totalHeight: height, width: geo.size.width)
                    }
                }
            }
            .frame(height: height)
        }
    }

    private func blockView(_ item: LaidOut, range: (start: Int, end: Int), totalHeight: CGFloat, width: CGFloat) -> some View {
        let b = item.block
        let totalSec = Double(range.end - range.start) * 3600.0
        let cal = Calendar.current
        let rangeStart = cal.date(bySettingHour: range.start, minute: 0, second: 0, of: day)!
        let startOffset = b.start.timeIntervalSince(rangeStart)
        let duration = b.end.timeIntervalSince(b.start)
        let y = max(0, CGFloat(startOffset / totalSec) * totalHeight)
        let h = max(10, CGFloat(duration / totalSec) * totalHeight)
        let gutter: CGFloat = item.totalLanes > 1 ? 3 : 0
        let laneWidth = (width - gutter * CGFloat(item.totalLanes - 1)) / CGFloat(item.totalLanes)
        let x = CGFloat(item.lane) * (laneWidth + gutter)
        return HStack(spacing: 0) {
            Text(b.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(width: laneWidth, height: h)
        .background(RoundedRectangle(cornerRadius: 4).fill(b.color.opacity(0.85)))
        .offset(x: x, y: y)
    }

    private func hourLabel(_ h: Int) -> String {
        let mod = h % 12 == 0 ? 12 : h % 12
        let ampm = h < 12 ? "a" : "p"
        return "\(mod)\(ampm)"
    }
}
