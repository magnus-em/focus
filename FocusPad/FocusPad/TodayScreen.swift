import SwiftUI
import SwiftData
import FocusCore

/// The day's log, fixable from the phone: what Focus noticed (written on the
/// Mac), things to fix, "tell Focus what happened", and every block, newest
/// first. Edits are undoable except where they move the running timer.
struct TodayScreen: View {
    @EnvironmentObject private var engine: FocusTimerEngine
    @EnvironmentObject private var settings: PadSettings
    @Environment(\.modelContext) private var context
    @ObservedObject private var briefs = DayBriefStore.shared
    @Query(sort: \StoredWorkSession.startTime, order: .reverse) private var sessions: [StoredWorkSession]

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var editing: LogRow?
    @State private var filling: Gap?
    @State private var lastChange: Change?
    @State private var said = ""
    @State private var preview: [LogCorrection.Block]?
    @State private var reading = false
    @State private var readProblem: String?
    @State private var telling = false
    @AppStorage("phoneDismissedFixes") private var dismissedRaw = ""

    struct Change {
        var text: String
        var undos: [LogEdit.Undo]
        var movedTimer: Bool
    }

    struct Gap: Identifiable {
        var start: Date
        var end: Date
        var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var actions: LogActions { LogActions(engine: engine, context: context) }
    private var rows: [LogRow] {
        let start = day.addingTimeInterval(-86400), end = day.addingTimeInterval(2 * 86400)
        return LogRow.rows(sessions.filter { $0.startTime < end && $0.startTime > start.addingTimeInterval(-86400) },
                           engine: engine, day: day)
    }
    private var brief: DayBrief? { briefs.brief(for: day) }
    private var dismissed: Set<String> { Set(dismissedRaw.split(separator: "|").map(String.init)) }

    var body: some View {
        let rows = self.rows
        List {
            Section {
                Text("\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · Your log for the day. Fix what's wrong here; it syncs to your Mac.")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if let change = lastChange { changeBanner(change) }
            if let brief, brief.headline != nil || !brief.courses.isEmpty { summary(brief) }
            fixSection(rows)
            totals(rows)
            logSection(rows)
        }
        .listStyle(.insetGrouped)
        .readableWidth()
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous day")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
            }
        }
        .sheet(item: $editing) { row in
            BlockEditSheet(row: row, tags: settings.tags) { start, end, label, delete in
                edit(row, start: start, end: end, label: label, delete: delete)
            }
        }
        .confirmationDialog(filling.map { "\(clock($0.start))–\(clock($0.end))" } ?? "", isPresented: Binding(
            get: { filling != nil }, set: { if !$0 { filling = nil } }
        ), titleVisibility: .visible) {
            if let gap = filling {
                ForEach(settings.tags, id: \.self) { tag in
                    Button(tag) { record(actions.set(gap.start, gap.end, to: tag), "\(clock(gap.start))–\(clock(gap.end)) is now \(tag).") }
                }
                Button("Break") { record(actions.set(gap.start, gap.end, to: nil), "\(clock(gap.start))–\(clock(gap.end)) is now Break.") }
            }
        }
        .refreshable { briefs.reload() }
        .sheet(isPresented: $telling) {
            NavigationStack {
                List { tellSection }
                    .navigationTitle("Tell Focus what happened")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { telling = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: - Undo

    private func changeBanner(_ change: Change) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.text)
                    if change.movedTimer {
                        Text("The running timer moved too; Undo doesn't move it back.").font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
                Spacer()
                if !change.undos.isEmpty {
                    Button("Undo") {
                        if actions.undo(change.undos) { lastChange = nil } else {
                            lastChange = Change(text: "Can't undo: the log changed since.", undos: [], movedTimer: false)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func record(_ out: LogActions.Outcome, _ text: String) {
        if let problem = out.problem {
            lastChange = Change(text: problem, undos: out.undos, movedTimer: out.movedTimer)
        } else {
            lastChange = Change(text: text, undos: out.undos, movedTimer: out.movedTimer)
            Haptics.success()
        }
    }

    // MARK: - Focus's summary

    private func summary(_ brief: DayBrief) -> some View {
        Section {
            if let headline = brief.headline {
                Text(headline).padding(.vertical, 2)
            }
            if !brief.courses.isEmpty || !brief.noticed.isEmpty {
                DisclosureGroup("What you studied") { studied(brief) }
            }
        } header: {
            Label("Focus noticed", systemImage: "sparkles")
        } footer: {
            Text(brief.headlineAsOf.map { "Written at \(clock($0)) from your Mac's screen and timer; fixes as of \(clock(brief.written))." }
                 ?? "From your Mac, as of \(clock(brief.written)).")
        }
    }

    @ViewBuilder
    private func studied(_ brief: DayBrief) -> some View {
            ForEach(brief.courses, id: \.code) { course in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(course.code).fontWeight(.semibold)
                        Spacer()
                        Text(durationText(minutes: course.minutes)).foregroundStyle(Color.secondaryText).monospacedDigit()
                    }
                    if !course.topics.isEmpty {
                        Text(course.topics.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                    if !course.shaky.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text("Looked shaky: " + course.shaky.joined(separator: "; ")).font(.subheadline).foregroundStyle(Color.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            ForEach(brief.noticed, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Color.secondaryText) }
    }

    // MARK: - Fixes

    private enum Fix: Identifiable {
        case mac(DayBrief.Fix)
        case gap(Gap)
        case overlap(SessionOverlap)

        var id: String {
            switch self {
            case .mac(let f): return "mac-\(f.id)"
            case .gap(let g): return "gap-\(g.id)"
            case .overlap(let o): return "overlap-\(o.first.id)-\(o.second.id)"
            }
        }
    }

    private func fixes(_ rows: [LogRow]) -> [Fix] {
        var out: [Fix] = []
        let now = Date()
        for f in brief?.fixes ?? [] where !dismissed.contains("mac-\(f.id)") && !resolved(f, rows) {
            out.append(.mac(f))
        }
        for g in LogRow.gaps(rows, day: day, now: now) {
            let gap = Gap(start: g.start, end: g.end)
            let covered = out.contains { if case .mac(let f) = $0 { return f.start < g.end && f.end > g.start }; return false }
            if !covered, !dismissed.contains("gap-\(gap.id)"), now.timeIntervalSince(g.end) > 60 || !engine.isActive {
                out.append(.gap(gap))
            }
        }
        let cal = Calendar.current
        let values = sessions.filter { $0.startTime < cal.date(byAdding: .day, value: 1, to: day)! && $0.startTime > day.addingTimeInterval(-86400) }
            .map(\.asValue)
        for o in TimeIntegrity.overlaps(in: values, from: day, to: cal.date(byAdding: .day, value: 1, to: day)!) {
            out.append(.overlap(o))
        }
        return out.sorted { start(of: $0) < start(of: $1) }
    }

    private func start(of fix: Fix) -> Date {
        switch fix {
        case .mac(let f): return f.start
        case .gap(let g): return g.start
        case .overlap(let o): return o.start
        }
    }

    /// The Mac rewrites its fixes every few minutes; one fixed here since then is hidden.
    private func resolved(_ f: DayBrief.Fix, _ rows: [LogRow]) -> Bool {
        let total = f.end.timeIntervalSince(f.start)
        guard total > 0 else { return true }
        let covered = rows.filter { row in f.suggestion.map { row.label == $0 } ?? true }
            .map { max(0, min($0.end, f.end).timeIntervalSince(max($0.start, f.start))) }
            .reduce(0, +)
        return covered / total >= 0.8
    }

    @ViewBuilder
    private func fixSection(_ rows: [LogRow]) -> some View {
        let list = fixes(rows)
        let canTell = isToday || Calendar.current.isDateInYesterday(day)
        if !list.isEmpty || canTell {
            Section {
                ForEach(list) { fix in fixRow(fix) }
                if canTell {
                    Button { telling = true } label: {
                        HStack {
                            Label(list.isEmpty ? "Something wrong? Tell Focus what happened" : "Something else wrong? Tell Focus",
                                  systemImage: "text.bubble")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 36)
                    }
                }
            } header: {
                if !list.isEmpty {
                    Text(list.count == 1 ? "1 thing to fix" : "\(list.count) things to fix").foregroundStyle(Color.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func fixRow(_ fix: Fix) -> some View {
        switch fix {
        case .mac(let f):
            VStack(alignment: .leading, spacing: 8) {
                Text(f.text)
                HStack(spacing: 10) {
                    if let s = f.suggestion {
                        Button("Make it \(s)") { record(actions.set(f.start, f.end, to: s), "\(clock(f.start))–\(clock(f.end)) is now \(s).") }
                            .buttonStyle(.borderedProminent).tint(categoryColor(s)).lineLimit(1).fixedSize()
                    }
                    Button("Other…") { filling = Gap(start: f.start, end: f.end) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Leave it") { dismiss(fix.id) }.font(.subheadline).foregroundStyle(Color.secondaryText).frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
            .padding(.vertical, 4)
        case .gap(let g):
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing logged \(clock(g.start))–\(clock(g.end)) (\(durationText(minutes: g.end.timeIntervalSince(g.start) / 60))).")
                HStack(spacing: 10) {
                    Button("Fill in…") { filling = g }.buttonStyle(.borderedProminent).tint(.accentColor)
                    Spacer()
                    Button("Leave it") { dismiss(fix.id) }.font(.subheadline).foregroundStyle(Color.secondaryText).frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
            .padding(.vertical, 4)
        case .overlap(let o):
            let a = o.first.type.isBreak ? "Break" : (o.first.label ?? "Focus")
            let b = o.second.type.isBreak ? "Break" : (o.second.label ?? "Focus")
            VStack(alignment: .leading, spacing: 8) {
                Text(o.sameLabel ? "\(a) is logged twice \(clock(o.start))–\(clock(o.end))."
                     : "\(a) and \(b) are both logged \(clock(o.start))–\(clock(o.end)).")
                HStack(spacing: 10) {
                    if o.sameLabel {
                        Button("Merge") { record(actions.fixOverlap(o, keep: nil), "Merged the two \(a) blocks.") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Keep \(a)") { record(actions.fixOverlap(o, keep: o.first.id), "Kept \(a) for that stretch.") }
                            .buttonStyle(.bordered)
                        Button("Keep \(b)") { record(actions.fixOverlap(o, keep: o.second.id), "Kept \(b) for that stretch.") }
                            .buttonStyle(.bordered)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
            .padding(.vertical, 4)
        }
    }

    private func dismiss(_ id: String) {
        dismissedRaw = (Array(dismissed) + [id]).suffix(200).joined(separator: "|")
    }

    // MARK: - Tell Focus

    private var tellSection: some View {
        Section {
            TextField("e.g. reading since 8:30", text: $said, axis: .vertical)
                .lineLimit(1...4)
                .submitLabel(.done)
                .onSubmit(read)
            if let preview {
                ForEach(Array(preview.enumerated()), id: \.offset) { _, block in
                    HStack {
                        Circle().fill(block.category.map(categoryColor) ?? FocusColors.breakBlue).frame(width: 8, height: 8)
                        Text(block.category ?? "Break").fontWeight(.semibold)
                        Spacer()
                        Text("\(clock(block.start))–\(clock(block.end))").monospacedDigit().foregroundStyle(Color.secondaryText)
                    }
                }
                HStack {
                    Button("Apply") { applyPreview(preview) }.buttonStyle(.borderedProminent)
                    Button("Cancel") { self.preview = nil }.buttonStyle(.bordered)
                }
                .buttonStyle(.borderless)
            } else {
                Button(reading ? "Reading…" : "Preview change") { read() }
                    .disabled(said.trimmingCharacters(in: .whitespaces).isEmpty || reading)
            }
            if let readProblem { Text(readProblem).font(.footnote).foregroundStyle(.orange) }
        } footer: {
            Text("Times and categories in plain words, like “the last 30 min was chores” or “sleep 11:30pm to 8:30, then reading”. You see the change before anything is saved.")
        }
    }

    private func read() {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        readProblem = nil
        let now = Date()
        let log = rows.map { (start: $0.start, end: $0.end, label: $0.name) }
        let categories = settings.tags
        reading = true
        Task { @MainActor in
            var blocks: [LogCorrection.Block]?
            if #available(iOS 26.0, *) {
                blocks = await LogCorrection.propose(text, log: log, now: now, categories: categories)
            } else {
                blocks = LogCorrection.parse(text, categories: categories).map {
                    LogCorrection.validate($0, now: now, categories: categories, log: log)
                }
            }
            reading = false
            guard let blocks, !blocks.isEmpty else {
                readProblem = "Couldn't find times in that. Try “chores for the last 30 min” or “class 1–1:40, then leisure”."
                return
            }
            preview = blocks
        }
    }

    private func applyPreview(_ blocks: [LogCorrection.Block]) {
        var undos: [LogEdit.Undo] = []
        var moved = false
        var problem: String?
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            let out = actions.set(block.start, block.end, to: block.category)
            undos += out.undos
            moved = moved || out.movedTimer
            if let p = out.problem { problem = p; break }
        }
        lastChange = Change(text: problem ?? "Saved what you said.", undos: undos, movedTimer: moved)
        preview = nil
        said = ""
        if problem == nil { telling = false }
        if problem == nil { Haptics.success() }
    }

    // MARK: - Totals and log

    private func totals(_ rows: [LogRow]) -> some View {
        var byLabel: [String: Double] = [:]
        for row in rows { byLabel[row.name, default: 0] += row.minutes }
        let focus = rows.filter { $0.label.map { !FocusCategories.isLife($0) } ?? false }.map(\.minutes).reduce(0, +)
        let top = byLabel.sorted { $0.value > $1.value }
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(durationText(minutes: focus)).font(.title2.weight(.semibold).monospacedDigit())
                    Text("focus of your \(settings.dailyGoalHours)h goal").foregroundStyle(Color.secondaryText)
                }
                DayStrip(rows: rows, day: day)
                FlowRows(items: top.map { ($0.key, $0.value) })
            }
            .padding(.vertical, 4)
        }
    }

    private func logSection(_ rows: [LogRow]) -> some View {
        let gaps = LogRow.gaps(rows, day: day).map { Gap(start: $0.start, end: $0.end) }
        enum Item: Identifiable {
            case row(LogRow), gap(Gap)
            var id: String { switch self { case .row(let r): return r.id.uuidString; case .gap(let g): return g.id } }
            var start: Date { switch self { case .row(let r): return r.start; case .gap(let g): return g.start } }
        }
        let items = (rows.map(Item.row) + gaps.map(Item.gap)).sorted { $0.start > $1.start }
        return Section {
            if items.isEmpty { Text("Nothing logged.").foregroundStyle(Color.secondaryText) }
            ForEach(items) { item in
                switch item {
                case .row(let row):
                    Button { editing = row } label: { LogRowView(row: row, line: line(for: row)) }
                        .foregroundStyle(.primary)
                case .gap(let gap):
                    Button { filling = gap } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                                .foregroundStyle(Color.secondaryText).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Untracked").foregroundStyle(Color.secondaryText)
                                Text("\(clock(gap.start))–\(clock(gap.end)) · \(durationText(minutes: gap.end.timeIntervalSince(gap.start) / 60))")
                                    .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                            }
                            Spacer()
                            Text("Fill in").font(.subheadline).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text("Log")
        } footer: {
            Text("Tap a block to change its category or times.")
        }
    }

    /// What the Mac saw during this block, from the brief.
    private func line(for row: LogRow) -> String? {
        brief?.blocks.first { b in
            min(b.end, row.end).timeIntervalSince(max(b.start, row.start)) > row.end.timeIntervalSince(row.start) / 2
        }.flatMap { b in b.line ?? (b.title != row.name ? b.title : nil) }
    }

    private func edit(_ row: LogRow, start: Date, end: Date, label: String?, delete: Bool) {
        if row.running {
            if delete { return }
            let out = start < row.start ? actions.start(label ?? row.name, at: start)
                : actions.set(row.start, Date(), to: label)
            record(out, "\(label ?? "Break") since \(clock(min(start, row.start))).")
            return
        }
        if delete {
            record(actions.clear(row.start, row.end), "Removed \(row.name) \(clock(row.start))–\(clock(row.end)).")
            return
        }
        var undos: [LogEdit.Undo] = []
        if start > row.start || end < row.end {
            let out = actions.clear(row.start, row.end)
            guard out.problem == nil else { return record(out, "") }
            undos += out.undos
        }
        let out = actions.set(start, end, to: label)
        record(LogActions.Outcome(undos: undos + out.undos, movedTimer: out.movedTimer, problem: out.problem),
               "\(clock(start))–\(clock(end)) is now \(label ?? "Break").")
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day) else { return }
        day = min(next, Calendar.current.startOfDay(for: Date()))
        preview = nil
        lastChange = nil
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

private struct LogRowView: View {
    let row: LogRow
    let line: String?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(row.label.map(categoryColor) ?? FocusColors.breakBlue)
                .frame(width: 4, height: line == nil ? 30 : 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).fontWeight(.semibold)
                    if row.running { Text("now").font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText) }
                }
                Text("\(clock(row.start))–\(row.running ? "now" : clock(row.end)) · \(durationText(minutes: row.minutes))")
                    .font(.footnote).foregroundStyle(Color.secondaryText).monospacedDigit()
                if let line { Text(line).font(.footnote).foregroundStyle(Color.secondaryText).lineLimit(2) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

/// Category totals as small labeled chips that wrap.
private struct FlowRows: View {
    let items: [(String, Double)]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 104), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    Circle().fill(item.0 == "Break" ? FocusColors.breakBlue : categoryColor(item.0)).frame(width: 7, height: 7)
                    Text(item.0).font(.footnote)
                    Text(durationText(minutes: item.1)).font(.footnote.monospacedDigit()).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }
}

// MARK: - Edit one block

private struct BlockEditSheet: View {
    let row: LogRow
    let tags: [String]
    let save: (Date, Date, String?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String?
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(tags + ["Break"], id: \.self) { tag in
                            let value: String? = tag == "Break" ? nil : tag
                            let color = value.map(categoryColor) ?? FocusColors.breakBlue
                            Button { label = value } label: {
                                Text(tag).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(label == value ? color : color.opacity(0.14)))
                                    .foregroundStyle(label == value ? Color.white : color)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Time") {
                    DatePicker("Start", selection: $start, in: ...(row.running ? Date() : end), displayedComponents: [.date, .hourAndMinute])
                    if !row.running {
                        DatePicker("End", selection: $end, in: start...Date(), displayedComponents: [.date, .hourAndMinute])
                    }
                }
                if row.running {
                    Section {
                        Text("This block is running. A new category applies from its start; an earlier start relabels the time in between.")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                } else {
                    Section {
                        Button("Remove this block", role: .destructive) {
                            save(row.start, row.end, row.label, true)
                            dismiss()
                        }
                    } footer: {
                        Text("Removing leaves the time untracked. A shorter block leaves the rest untracked too.")
                    }
                }
            }
            .navigationTitle(row.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(start, row.running ? row.end : end, label, false)
                        dismiss()
                    }
                    .disabled(label == row.label && abs(start.timeIntervalSince(row.start)) < 30 && abs(end.timeIntervalSince(row.end)) < 30)
                }
            }
            .onAppear {
                label = row.label
                start = row.start
                end = row.end
            }
        }
    }
}
