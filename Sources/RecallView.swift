import SwiftUI
import AppKit
import Charts
import FocusCore

final class RecallWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func open(store: RecallStore, settings: AppSettings, sessionStore: SessionStore) {
        store.refresh()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = RecallView(store: store, settings: settings, sessionStore: sessionStore)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Recall"
        w.setContentSize(NSSize(width: 980, height: 720))
        w.minSize = NSSize(width: 820, height: 600)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private func shortDays(_ d: Double) -> String {
    let n = Int(d.rounded())
    if n < 30 { return "\(n)d" }
    if n < 365 { return "\(n / 30)mo" }
    return "\(n / 365)y"
}

private func dueLabel(_ date: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    if days <= 0 { return "due" }
    if days == 1 { return "tomorrow" }
    return "in \(shortDays(Double(days)))"
}

private func pct(_ r: Double?) -> String { r.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

private func gradeColor(_ g: RecallGrade) -> Color {
    switch g {
    case .forgot: return .red
    case .partial: return .orange
    case .got: return .green
    case .fluent: return Color(red: 0.2, green: 0.6, blue: 0.95)
    }
}

private func sectionLabel(_ s: String) -> some View {
    Text(s)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.secondaryText)
}

/// Retrieval practice: review due cards, manage cards, read recall notes,
/// and see whether retention is actually improving.
struct RecallView: View {
    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessionStore: SessionStore

    enum Tab: String, CaseIterable { case review = "Review", cards = "Cards", journal = "Journal", progress = "Progress" }
    @State private var tab: Tab = .review
    @State private var newCardToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                let due = store.dueCount(cap: settings.recallDailyCap)
                if due > 0 {
                    Text("\(due) due today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(recallPurple)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(recallPurple.opacity(0.12)))
                }
                Button {
                    tab = .cards
                    newCardToken += 1
                } label: {
                    Label("New card", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            switch tab {
            case .review: ReviewSessionView(store: store, settings: settings)
            case .cards: CardsBrowser(store: store, settings: settings, newCardToken: newCardToken)
            case .journal: JournalView(store: store)
            case .progress: RecallProgressView(store: store, settings: settings, sessionStore: sessionStore)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Review

private struct ReviewSessionView: View {
    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings

    @State private var queue: [StoredKnowledgeItem] = []
    @State private var index = 0
    @State private var started = false
    @State private var response = ""
    @State private var revealed = false
    @State private var hints: [String] = []
    @State private var hintLoading = false
    @State private var shownAt = Date()
    @State private var answerSeconds: Double = 0
    @State private var aiGrade: RecallCoach.Grade?
    @State private var aiLoading = false
    @State private var aiError: String?
    @State private var sessionResults: [(RecallGrade, Bool)] = []
    @FocusState private var editorFocused: Bool

    private var current: StoredKnowledgeItem? { index < queue.count ? queue[index] : nil }

    var body: some View {
        Group {
            if started, let item = current {
                ScrollView { card(item).frame(maxWidth: 680).padding(.vertical, 28).frame(maxWidth: .infinity) }
            } else if started {
                finished
            } else {
                start
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var start: some View {
        let due = store.todayQueue(cap: settings.recallDailyCap)
        return VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(recallPurple.opacity(0.8))
            if !due.isEmpty {
                Text("\(due.count) to recall today")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text("Answer each from memory before revealing. A blank attempt still counts — forgetting and then seeing the answer is how it sticks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    queue = due
                    index = 0
                    sessionResults = []
                    started = true
                    resetCard()
                } label: {
                    Text("Start").frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(recallPurple)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            } else if store.activeItems.isEmpty {
                Text("No cards yet")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Text("Cards come from the recall prompt after each focus block, or add your own under Cards. Each one comes back after 1, 3, 7, 14 and 30 days, sooner if you miss it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            } else {
                Text(store.due.isEmpty ? "Nothing due" : "Done for today")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                Group {
                    if !store.due.isEmpty {
                        Text("\(store.due.count) more are due, held back by the daily cap of \(settings.recallDailyCap).")
                    } else if let next = store.nextDueDate() {
                        Text("Next card \(dueLabel(next) == "tomorrow" ? "due tomorrow" : dueLabel(next)). \(store.activeItems.count) active cards.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(40)
    }

    private var finished: some View {
        let unaided = sessionResults.filter { $0.0 >= .got && !$0.1 }.count
        return VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text("\(sessionResults.count) reviewed")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("\(unaided) recalled unaided · \(sessionResults.filter { $0.0 == .forgot }.count) forgot")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Back") { started = false }
                .controlSize(.small)
        }
        .padding(40)
    }

    @ViewBuilder
    private func card(_ item: StoredKnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("\(index + 1) of \(queue.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                if !item.course.isEmpty {
                    Text(item.course)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(categoryColor(item.course))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(categoryColor(item.course).opacity(0.14)))
                }
                Label(item.kind.displayName, systemImage: item.kind.icon)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { advance() }
                    .controlSize(.small)
                    .help("Move on without grading; it stays due")
            }

            Text(item.prompt)
                .font(.system(size: 21, weight: .regular, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $response)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($editorFocused)
                    .disabled(revealed)
                if response.isEmpty {
                    Text(revealed ? "(answered in your head)" : "Write it out from memory — explanation, steps, formula, code…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: revealed ? 70 : 170)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))

            if !hints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(hints.enumerated()), id: \.offset) { i, h in
                        Label(h, systemImage: "lightbulb")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !revealed {
                HStack {
                    Button {
                        nextHint(item)
                    } label: {
                        if hintLoading { ProgressView().controlSize(.small) } else { Label("Hint", systemImage: "lightbulb") }
                    }
                    .disabled(hintLoading || hints.count >= 3)
                    .help("A hint caps this attempt at Partial")
                    Spacer()
                    Button("Reveal answer") { reveal() }
                        .buttonStyle(.borderedProminent)
                        .tint(recallPurple)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                revealedSection(item)
            }
        }
        .padding(.horizontal, 28)
        .onAppear { editorFocused = true }
    }

    @ViewBuilder
    private func revealedSection(_ item: StoredKnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Reference")
                if item.answerByAI {
                    Text("drafted by Claude · unverified")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                    Button("Looks right") { store.update(item) { $0.answerByAI = false } }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                Spacer()
                if !item.source.isEmpty {
                    Text(item.source).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text(item.answer.isEmpty ? "(no reference answer)" : item.answer)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(recallPurple.opacity(0.07)))
        }

        if RecallCoach.isConfigured && !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let g = aiGrade {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(recallPurple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claude suggests: \(g.score.displayName)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(gradeColor(g.score))
                        Text(g.feedback)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        check(item)
                    } label: {
                        if aiLoading { ProgressView().controlSize(.small) } else { Label("Check with Claude", systemImage: "sparkles") }
                    }
                    .disabled(aiLoading)
                    .controlSize(.small)
                    if let aiError { Text(aiError).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2) }
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(hints.isEmpty ? "HOW DID IT GO?" : "HOW DID IT GO?  (hint used — capped at Partial)")
            HStack(spacing: 8) {
                ForEach(RecallGrade.allCases, id: \.self) { g in
                    let allowed = hints.isEmpty || g <= .partial
                    Button {
                        grade(item, g)
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 3) {
                                if aiGrade?.score == g { Image(systemName: "sparkles").font(.system(size: 9)) }
                                Text(g.displayName).font(.system(size: 12, weight: .semibold))
                            }
                            Text(g.detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            Text("→ \(shortDays(store.previewInterval(item, grade: g, hinted: !hints.isEmpty)))")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(gradeColor(g).opacity(aiGrade?.score == g ? 0.22 : 0.1)))
                        .foregroundStyle(gradeColor(g))
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowed)
                    .opacity(allowed ? 1 : 0.35)
                    .keyboardShortcut(KeyEquivalent(Character("\(g.rawValue + 1)")), modifiers: [])
                }
            }
            Text("Keys 1–4. Only Got it / Fluent without a hint count as unaided recall.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func resetCard() {
        response = ""
        revealed = false
        hints = []
        aiGrade = nil
        aiError = nil
        aiLoading = false
        shownAt = Date()
        editorFocused = true
    }

    private func reveal() {
        answerSeconds = Date().timeIntervalSince(shownAt)
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
    }

    private func advance() {
        index += 1
        resetCard()
    }

    private func grade(_ item: StoredKnowledgeItem, _ g: RecallGrade) {
        let hinted = !hints.isEmpty
        store.record(item, response: response, grade: g, hinted: hinted, seconds: answerSeconds,
                     aiScore: aiGrade?.score, aiFeedback: aiGrade?.feedback ?? "")
        sessionResults.append((g, hinted))
        advance()
    }

    private func check(_ item: StoredKnowledgeItem) {
        aiLoading = true
        aiError = nil
        let p = item.prompt, a = item.answer, r = response
        Task { @MainActor in
            do { aiGrade = try await RecallCoach.grade(prompt: p, reference: a, response: r) }
            catch { aiError = error.localizedDescription }
            aiLoading = false
        }
    }

    private func nextHint(_ item: StoredKnowledgeItem) {
        guard RecallCoach.isConfigured else {
            hints.append(offlineHint(item.answer, level: hints.count + 1))
            return
        }
        hintLoading = true
        let p = item.prompt, a = item.answer, prev = hints, partial = response
        Task { @MainActor in
            do { hints.append(try await RecallCoach.hint(prompt: p, reference: a, previous: prev, partial: partial)) }
            catch { hints.append(offlineHint(a, level: prev.count + 1)) }
            hintLoading = false
        }
    }

    /// Without Claude: reveal the opening of the reference, a bit more each time.
    private func offlineHint(_ answer: String, level: Int) -> String {
        let words = answer.split(separator: " ")
        let n = max(1, Int(Double(words.count) * [0.12, 0.25, 0.45][min(level - 1, 2)]))
        return "Starts: “" + words.prefix(n).joined(separator: " ") + " …”"
    }
}

// MARK: - Cards

private struct CardsBrowser: View {
    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings
    let newCardToken: Int

    @State private var search = ""
    @State private var courseFilter: String? = nil
    @State private var showArchived = false
    @State private var selection: UUID? = nil
    @State private var creating = false
    @State private var showDraftSheet = false

    private var filtered: [StoredKnowledgeItem] {
        store.items.filter { item in
            (showArchived || !item.archived)
                && (courseFilter == nil || item.course == courseFilter)
                && (search.isEmpty || item.prompt.localizedCaseInsensitiveContains(search)
                    || item.answer.localizedCaseInsensitiveContains(search)
                    || item.topic.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.nextDue < $1.nextDue }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Menu(courseFilter ?? "All") {
                        Button("All") { courseFilter = nil }
                        ForEach(store.courses, id: \.self) { c in Button(c) { courseFilter = c } }
                    }
                    .fixedSize()
                }
                HStack {
                    Toggle("Archived", isOn: $showArchived)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Spacer()
                    Button {
                        showDraftSheet = true
                    } label: {
                        Label("Draft from notes", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .disabled(!RecallCoach.isConfigured)
                    .help(RecallCoach.isConfigured ? "Paste lecture notes or a textbook section; Claude proposes cards"
                                                   : "Needs a Claude API key (Settings → Recall)")
                }
                List(selection: $selection) {
                    ForEach(filtered, id: \.id) { item in
                        CardRow(item: item, attempts: store.attempts(for: item))
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .onChange(of: selection) { _, new in if new != nil { creating = false } }
                Text("\(filtered.count) cards")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(width: 360)

            Divider()

            Group {
                if creating {
                    CardEditor(store: store, settings: settings, item: nil) { id in
                        creating = false
                        selection = id
                    }
                    .id("new-\(newCardToken)")
                } else if let id = selection, let item = store.items.first(where: { $0.id == id }) {
                    CardEditor(store: store, settings: settings, item: item) { _ in selection = nil }
                        .id(id)
                } else {
                    VStack(spacing: 8) {
                        Text("Select a card, or add one.")
                            .foregroundStyle(.secondary)
                        Button("New card") { creating = true; selection = nil }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if newCardToken > 0 { creating = true; selection = nil } }
        .onChange(of: newCardToken) { _, _ in creating = true; selection = nil }
        .sheet(isPresented: $showDraftSheet) {
            DraftFromNotesSheet(store: store, settings: settings, isPresented: $showDraftSheet)
        }
    }
}

private struct CardRow: View {
    let item: StoredKnowledgeItem
    let attempts: [StoredRecallAttempt]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.prompt)
                .font(.system(size: 12))
                .lineLimit(2)
            HStack(spacing: 6) {
                if !item.course.isEmpty {
                    Text(item.course).foregroundStyle(categoryColor(item.course))
                }
                Text(item.archived ? "archived" : dueLabel(item.nextDue))
                    .foregroundStyle(!item.archived && item.nextDue <= Date() ? recallPurple : .secondary)
                if item.reps > 0 { Text("· \(item.reps)×").foregroundStyle(.tertiary) }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(attempts.prefix(5).reversed(), id: \.id) { a in
                        Circle().fill(gradeColor(a.grade).opacity(a.hinted ? 0.45 : 1)).frame(width: 5, height: 5)
                    }
                }
            }
            .font(.system(size: 10))
        }
        .padding(.vertical, 2)
    }
}

private struct CardEditor: View {
    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings
    let item: StoredKnowledgeItem?
    let onDone: (UUID?) -> Void

    @State private var course = ""
    @State private var topic = ""
    @State private var kind: KnowledgeKind = .concept
    @State private var prompt = ""
    @State private var answer = ""
    @State private var source = ""
    @State private var confirmDelete = false

    private var courseOptions: [String] {
        var seen = Set<String>()
        return (settings.tags.filter { !settings.lifeTags.contains($0) } + store.courses)
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item == nil ? "New card" : "Edit card")
                    .font(.system(size: 16, weight: .semibold))

                HStack(spacing: 10) {
                    Picker("Course", selection: $course) {
                        Text("—").tag("")
                        ForEach(courseOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 200)
                    Picker("Type", selection: $kind) {
                        ForEach(KnowledgeKind.allCases, id: \.self) { Label($0.displayName, systemImage: $0.icon).tag($0) }
                    }
                    .frame(width: 180)
                }
                TextField("Topic (not shown while reviewing)", text: $topic)
                    .textFieldStyle(.roundedBorder)

                sectionLabel("Prompt (ask for an explanation, derivation or reconstruction; don't give the answer away)")
                TextField("e.g. Why does an LSTM's cell state let gradients survive long sequences?", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)

                sectionLabel("Reference answer")
                TextField("What a correct answer contains", text: $answer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...14)
                TextField("Source (lecture, book section…)", text: $source)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    if let item {
                        Button(item.archived ? "Unarchive" : "Archive") {
                            store.update(item) { $0.archived.toggle() }
                        }
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                    Spacer()
                    Button(item == nil ? "Add card" : "Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(recallPurple)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let item {
                    history(item)
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete this card and its review history?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let item { store.delete(item) }
                onDone(nil)
            }
        }
    }

    @ViewBuilder
    private func history(_ item: StoredKnowledgeItem) -> some View {
        let hist = store.attempts(for: item)
        Divider().padding(.vertical, 4)
        HStack {
            sectionLabel("History")
            Spacer()
            Text("interval \(shortDays(item.intervalDays)) · \(item.archived ? "archived" : dueLabel(item.nextDue)) · \(item.lapses) lapses")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if hist.isEmpty {
            Text("Not reviewed yet.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        ForEach(hist, id: \.id) { a in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(a.grade.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(gradeColor(a.grade))
                    if a.hinted { Text("hint").font(.system(size: 9.5)).foregroundStyle(.orange) }
                    Text("after \(shortDays(a.delayDays))").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(a.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if !a.response.isEmpty {
                    Text(a.response).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                }
                if !a.aiFeedback.isEmpty {
                    Text(a.aiFeedback).font(.system(size: 10.5)).foregroundStyle(recallPurple).lineLimit(4)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
        }
    }

    private func load() {
        guard let item else {
            course = courseOptions.first ?? ""
            return
        }
        course = item.course
        topic = item.topic
        kind = item.kind
        prompt = item.prompt
        answer = item.answer
        source = item.source
    }

    private func save() {
        if let item {
            let answerChanged = item.answer != answer
            store.update(item) {
                $0.course = course
                $0.topic = topic
                $0.kind = kind
                $0.prompt = prompt
                $0.answer = answer
                $0.source = source
                if answerChanged { $0.answerByAI = false }
            }
            onDone(item.id)
        } else {
            let new = store.addItem(course: course, prompt: prompt, answer: answer, kind: kind, topic: topic, source: source)
            onDone(new.id)
        }
    }
}

private struct DraftFromNotesSheet: View {
    /// What the screen saw you study that day (focus blocks' notes), as material.
    @MainActor
    private func screenNotes(daysBack: Int) -> String {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysBack, to: cal.startOfDay(for: Date()))!
        let w = ScreenWatcher.shared
        var seen = Set<String>()
        return w.activities(from: day, to: cal.date(byAdding: .day, value: 1, to: day)!)
            .filter { ($0.category.map { !FocusCategories.isLife($0) } ?? false) && $0.minutes >= 5 }
            .compactMap { a -> String? in
                guard let n = w.notes(for: a), !n.bullets.isEmpty, seen.insert(n.title).inserted else { return nil }
                if course.isEmpty, let c = a.category { course = c }
                return "## \(n.title)\n" + n.bullets.map { "- \($0)" }.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings
    @Binding var isPresented: Bool

    @State private var course = ""
    @State private var material = ""
    @State private var drafts: [RecallCardDraft] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft cards from notes")
                .font(.system(size: 15, weight: .semibold))
            Picker("Course", selection: $course) {
                Text("—").tag("")
                ForEach(settings.tags.filter { !settings.lifeTags.contains($0) } + store.courses.filter { !settings.tags.contains($0) }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .frame(width: 240)
            if drafts.isEmpty {
                HStack(spacing: 12) {
                    Button("Use today's screen notes") { material = screenNotes(daysBack: 0) }
                    Button("Yesterday's") { material = screenNotes(daysBack: 1) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                TextEditor(text: $material)
                    .font(.system(size: 12))
                    .frame(minHeight: 260)
                    .overlay(alignment: .topLeading) {
                        if material.isEmpty {
                            Text("Paste lecture notes, a problem solution, or a textbook section…")
                                .foregroundStyle(.tertiary)
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                    }
                    .border(Color.primary.opacity(0.1))
            } else {
                ScrollView { DraftCardsEditor(drafts: $drafts) }
                    .frame(minHeight: 300)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                if drafts.isEmpty {
                    Button {
                        run()
                    } label: {
                        if loading { ProgressView().controlSize(.small) } else { Text("Draft cards") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recallPurple)
                    .disabled(loading || material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    let n = drafts.filter(\.include).count
                    Button("Add \(n)") {
                        store.addDrafts(drafts, course: course, noteID: nil)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recallPurple)
                    .disabled(n == 0)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { course = settings.tags.first { !settings.lifeTags.contains($0) } ?? "" }
    }

    private func run() {
        loading = true
        error = nil
        let m = material, c = course
        Task { @MainActor in
            do {
                drafts = try await RecallCoach.draftCards(from: m, course: c, max: 5)
                if drafts.isEmpty { error = "Claude didn't find anything card-worthy." }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

// MARK: - Journal

private struct JournalView: View {
    @ObservedObject var store: RecallStore

    private var days: [(Date, [StoredRecallNote])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: store.notes) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        if store.notes.isEmpty {
            Text("Recall notes you write after focus blocks and each morning land here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(days, id: \.0) { day, notes in
                        Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(notes, id: \.id) { n in noteCard(n) }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func noteCard(_ n: StoredRecallNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: n.kind == .yesterday ? "sun.horizon.fill" : "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundStyle(n.kind == .yesterday ? Color(red: 0.98, green: 0.6, blue: 0.2) : recallPurple)
                if n.kind == .yesterday {
                    Text("Reconstruction of the day before").font(.system(size: 12, weight: .semibold))
                } else {
                    Text(n.label.isEmpty ? "Focus" : n.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(categoryColor(n.label))
                    Text("· \(Int(n.sessionMinutes))m").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                let cards = store.cardCount(for: n)
                if cards > 0 {
                    Text("\(cards) card\(cards == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(recallPurple)
                }
                Text((n.sessionStart.map { $0.addingTimeInterval(n.sessionMinutes * 60) } ?? n.date)
                        .formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(n.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !n.aiFeedback.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10))
                    Text(n.aiFeedback).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(recallPurple)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(recallPurple.opacity(0.07)))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
        .contextMenu {
            Button("Delete note", role: .destructive) { store.delete(n) }
        }
    }
}

// MARK: - Progress

private struct RecallProgressView: View {
    @ObservedObject var store: RecallStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        let month = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let recent = store.attempts.filter { $0.date >= month }
        let delayed = recent.filter { $0.delayDays >= 5.5 }
        let coverage = store.noteCoverage(since: week, minMinutes: settings.recallMinMinutes, sessionStore: sessionStore)
        let buckets = store.retentionByDelay()
        let weeks = store.weeks(8, sessionStore: sessionStore)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    tile(pct(store.unaidedRate(recent)), "Unaided recall", "\(recent.count) reviews · 30 days")
                    tile(pct(store.unaidedRate(delayed)), "Retention after 1 week+", "\(delayed.count) reviews · 30 days")
                    tile("\(coverage.written)/\(coverage.eligible)", "Post-session recalls", "focus blocks ≥ \(settings.recallMinMinutes)m · 7 days")
                    tile("\(store.activeItems.count)", "Active cards", "\(store.due.count) due")
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Unaided recall by time since last seen")
                    Chart(buckets) { b in
                        BarMark(x: .value("Delay", b.label), y: .value("Unaided", (b.rate ?? 0) * 100))
                            .foregroundStyle(recallPurple.gradient)
                            .cornerRadius(3)
                            .annotation(position: .top) {
                                Text(b.attempts > 0 ? "\(pct(b.rate)) · n=\(b.attempts)" : "—")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .chartYScale(domain: 0...110)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                            AxisGridLine()
                            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 8)) }
                        }
                    }
                    .frame(height: 170)
                    Text("Expect this to fall as delays grow; the goal is a flatter slope over the months. Buckets with few reviews are noisy.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .glassCard(cornerRadius: 10)

                weeksTable(weeks)

                let hard = store.hardest()
                if !hard.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Keeps slipping")
                        ForEach(hard, id: \.id) { item in
                            HStack {
                                Text(item.prompt).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(item.lapses) lapses · \(item.reps) reviews")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 10)
                }

                Text("These numbers measure how well you retrieve what you studied, not memory capacity. Treat the first two weeks as a baseline, and expect harder material to pull them down.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
    }

    private func tile(_ value: String, _ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(sub).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 10)
    }

    private func weeksTable(_ weeks: [RecallWeek]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Week by week: is more study turning into more retention?")
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Week").gridColumnAlignment(.leading)
                    Text("Focus")
                    Text("Recalls")
                    Text("Reviews")
                    Text("Unaided")
                    Text("1 wk+ retention")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach(weeks.reversed()) { w in
                    GridRow {
                        Text(w.start.formatted(.dateTime.month(.abbreviated).day())).gridColumnAlignment(.leading)
                        Text(String(format: "%.1fh", w.focusHours))
                        Text("\(w.notes)")
                        Text("\(w.reviews)")
                        Text(pct(w.unaided))
                        Text(w.retentionN > 0 ? "\(pct(w.retention)) (\(w.retentionN))" : "—")
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10)
    }
}
