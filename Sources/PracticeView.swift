import AppKit
import FocusCore
import SwiftUI

// MARK: - Window controller

/// Standalone "Practice Mode" window. Same pattern as DashboardWindowController:
/// open/refocus, don't release on close (so the same instance persists across
/// open cycles and we don't lose the in-flight attempt if the user accidentally
/// hits the red dot).
@MainActor
final class PracticeWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    /// True if the user had Practice Mode open at the previous quit. Used
    /// at app launch to auto-restore the window so an in-progress problem
    /// (which the snapshot system already keeps warm) is immediately
    /// reachable without going through the popover.
    static var wasOpenAtQuit: Bool {
        UserDefaults.standard.bool(forKey: "practice.windowOpen")
    }

    func open(store: PracticeStore,
              homeworkStore: HomeworkStore,
              masteryStore: MasteryStore,
              answerOverridesStore: AnswerOverridesStore,
              problem: Stat110Problem? = nil) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let p = problem, !store.isActive { store.start(problem: p) }
            return
        }
        let view = PracticeView(store: store,
                                homeworkStore: homeworkStore,
                                masteryStore: masteryStore,
                                answerOverridesStore: answerOverridesStore,
                                initialProblem: problem)
        let vc = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: vc)
        w.title = "Practice Mode"
        // Size to most of the available screen so the problem, mastery
        // pill, answer reveal, and outcome buttons all fit without
        // resizing. Cap at sensible bounds for very large displays.
        let screen = w.screen ?? NSScreen.main
        let avail = screen?.visibleFrame.size ?? NSSize(width: 900, height: 1100)
        let targetW = min(900, max(720, avail.width - 80))
        let targetH = min(1180, max(820, avail.height - 60))
        w.setContentSize(NSSize(width: targetW, height: targetH))
        w.minSize = NSSize(width: 560, height: 720)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        UserDefaults.standard.set(true, forKey: "practice.windowOpen")
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "practice.windowOpen")
    }
}

// MARK: - Main view

struct PracticeView: View {
    @ObservedObject var store: PracticeStore
    @ObservedObject var homeworkStore: HomeworkStore
    @ObservedObject var masteryStore: MasteryStore
    @ObservedObject var answerOverridesStore: AnswerOverridesStore
    let initialProblem: Stat110Problem?

    @State private var showMonteCarloSheet = false
    @State private var showPicker = false

    /// Transient confirmation banner shown on the idle screen for a few
    /// seconds after each outcome — surfaces the scheduling consequence
    /// ("Next review tomorrow 7pm") in plain language so the user knows
    /// exactly what their click just did.
    @State private var outcomeBanner: OutcomeBanner? = nil

    struct OutcomeBanner: Equatable {
        let title: String
        let detail: String
        let icon: String
        let color: Color
    }

    // Quote stays stable for the duration of a problem — only changes
    // when the user navigates to a new problem. Avoids the "churn" the
    // user pushed back on. Seed is the catalog id, so it's deterministic
    // per problem.
    @State private var lastZone: PracticeStore.Zone = .green
    // How many progressive solution steps have been revealed. 0 = nothing
    // shown, 1 = first step visible, etc. Resets to 0 on problem change.
    /// Problem ID for which the answer is currently revealed. Storing the
    /// ID (rather than a bare Bool) means navigating to a different problem
    /// can never carry over the prior reveal — the comparison auto-fails.
    @State private var revealedAnswerID: String? = nil
    @State private var copiedProblem: Bool = false
    @State private var showResetConfirm = false
    // User-controlled font scale for the practice mode UI. Persisted so
    // the choice survives across launches. Range: 0.8 to 1.6.
    @AppStorage("practice.fontScale") private var fontScale: Double = 1.0
    /// Daily cap on fresh familiarizations. Default 5 per the design
    /// proposal; settable in Settings.
    @AppStorage("practice.dailyNewCap") private var dailyNewCap: Int = 5

    var body: some View {
        Group {
            if store.isActive {
                activeView
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let p = initialProblem, !store.isActive {
                store.start(problem: p)
            }
        }
        .sheet(isPresented: $showMonteCarloSheet) {
            MonteCarloSheet(store: store, isPresented: $showMonteCarloSheet)
        }
        .sheet(isPresented: $showPicker) {
            PracticeProblemPicker(homeworkStore: homeworkStore, isPresented: $showPicker) { p in
                store.start(problem: p)
            }
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                idleHeader

                if let banner = outcomeBanner {
                    outcomeBannerCard(banner)
                }

                reviewSessionCard

                familiarizeCard

                Divider().opacity(0.5)

                masteryDashboard

                if !groupedRecentSessions.isEmpty {
                    recentAttemptsList
                }

                resetHistoryFooter
            }
            .padding(.vertical, 4)
        }
    }

    private func outcomeBannerCard(_ b: OutcomeBanner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: b.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(b.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(b.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                outcomeBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .iconTarget()
            }
            .buttonStyle(.plainHit)
            .padding(-12)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(b.color.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(b.color.opacity(0.42), lineWidth: 0.7))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var idleHeader: some View {
        let dailyQuote = PracticeQuotes.daily(.idleScreen)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Today's plan")
                .font(.system(size: 26, weight: .semibold, design: .serif))
            Text(dailyQuote.text)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !dailyQuote.author.isEmpty {
                Text("— \(dailyQuote.author)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 4)
    }

    /// Top card: start the cold review session if any problems are due.
    /// When nothing's due, shows "all caught up" instead of a dead button.
    private var reviewSessionCard: some View {
        let dueRecords = masteryStore.dueNow
        let dueCount = dueRecords.count
        return VStack(alignment: .leading, spacing: 8) {
            if dueCount > 0 {
                Button {
                    startReviewSessionFromMastery()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start review session")
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(dueCount) problem\(dueCount == 1 ? "" : "s") due · cold, interleaved by topic")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.85)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plainHit)

                // Topic mix preview — gives a sense of what's coming.
                let mix = masteryStore.dueTopicMix()
                if !mix.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(mix.prefix(5), id: \.topic) { item in
                            Text("\(item.count) \(item.topic)")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.10)))
                                .foregroundStyle(.green)
                        }
                        if mix.count > 5 {
                            Text("+ \(mix.count - 5) more")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All caught up on reviews")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Nothing due today. Familiarize something new below to grow the queue.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.20), lineWidth: 0.6))
            }
        }
    }

    /// Middle card: pick up a new problem to familiarize with. Capped by
    /// the daily-new-cap setting; greys out when at cap so the user
    /// finishes reviews before piling on.
    private var familiarizeCard: some View {
        let used = newFamiliarizationsToday
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Familiarize something new")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(used) today")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                showPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("Browse Stat 110 catalog")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plainHit)
            .help("Open the full Stat 110 catalog to pick something new to familiarize.")
        }
    }

    /// Bottom strip: mastery counts at a glance — retained / R1 / R2 / R3 / new.
    private var masteryDashboard: some View {
        let c = masteryStore.counts
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Mastery")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                masteryCell(value: c.retained, label: "Retained",
                            color: .green)
                masteryCell(value: c.r2, label: "R3 due next",
                            color: .blue)
                masteryCell(value: c.r1, label: "R2 due next",
                            color: .purple)
                masteryCell(value: c.familiarized, label: "R1 due next",
                            color: .orange)
                masteryCell(value: c.lapsed, label: "Lapsed",
                            color: .red.opacity(0.7))
            }
            Text("Familiarized today: \(newFamiliarizationsToday). Goal: ladder up via cold reviews at 24 h → 2–3 d → 7 d.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func masteryCell(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.18), lineWidth: 0.5))
    }

    /// Counts familiarization attempts logged today, as a proxy for "new
    /// problems started today" against the daily cap.
    private var newFamiliarizationsToday: Int {
        let cal = Calendar.current
        return store.attempts.filter {
            cal.isDateInToday($0.startTime)
                && ($0.outcome == .solved || $0.outcome == .aiWalkthrough || $0.outcome == .stuck)
                && $0.hintsPeeked >= 0  // best-effort heuristic — every familiarization writes one of these outcomes
        }.count
    }

    /// Launch a cold review session from the interleaved due queue.
    /// Resolves catalog problems from mastery records and starts the
    /// session. No-op if nothing's due (defensive — the button is hidden
    /// in that case).
    private func startReviewSessionFromMastery() {
        let queue = masteryStore.interleavedDueQueue()
            .compactMap { Stat110Catalog.problem(id: $0.catalogID) }
        guard !queue.isEmpty else { return }
        store.startReviewSession(queue)
    }

    /// Destructive action — wipes all past drill attempts + homework rows.
    /// Confirmation alert before doing anything. Lives at the very bottom
    /// of the idle screen so it's discoverable but easy to ignore.
    private var resetHistoryFooter: some View {
        VStack(spacing: 4) {
            Divider().opacity(0.4).padding(.vertical, 6)
            Button {
                showResetConfirm = true
            } label: {
                Text("Reset practice & homework history…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plainHit)
            .help("Delete all past attempts and homework rows. Sessions, day records, scratchpad, and problem entries are untouched.")
            .alert("Reset all practice history?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    store.clearAllPracticeData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes every drill attempt and homework row. Sessions, day records, scratchpad, and the problem inbox are kept. This cannot be undone.")
            }
        }
    }

    // MARK: - Continue working

    /// Homework items linked to the Stat 110 catalog that the user hasn't
    /// nailed yet — anything that isn't `.solid` confidence, or that's
    /// explicitly flagged needsReview. Sorted by review-due first, then
    /// most-recently-touched.
    private var inProgressHomework: [HomeworkProblem] {
        homeworkStore.items
            .filter { $0.catalogID != nil }
            .filter { $0.confidence != .solid || $0.needsReview }
            .sorted { lhs, rhs in
                // Due-for-review first, then by most-recent date desc
                switch (lhs.isDueForReview, rhs.isDueForReview) {
                case (true, false): return true
                case (false, true): return false
                default: return lhs.date > rhs.date
                }
            }
    }

    private var continueWorkingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("CONTINUE WORKING")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(inProgressHomework.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 4) {
                ForEach(inProgressHomework.prefix(8)) { hw in
                    continueRow(hw)
                }
            }
        }
    }

    @ViewBuilder
    private func continueRow(_ hw: HomeworkProblem) -> some View {
        let resumeProblem = hw.catalogID.flatMap { Stat110Catalog.problem(id: $0) }
        let rowContents = HStack(spacing: 8) {
            Circle()
                .fill(confidenceColor(hw.confidence))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(hw.title.isEmpty ? hw.source : hw.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if hw.isDueForReview {
                        Text("DUE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.6)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.22)))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(hw.source) · \(hw.confidence.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if resumeProblem != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.16)))
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.05)))

        if let problem = resumeProblem {
            Button { store.start(problem: problem) } label: { rowContents }
                .buttonStyle(.plainHit)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
        } else {
            rowContents
        }
    }

    private var todayStatsRow: some View {
        HStack(spacing: 14) {
            statCard(label: "Today", value: "\(store.sessionsToday)", sub: "sessions")
            statCard(label: "Solved", value: String(format: "%.0f%%", store.solveRateToday * 100), sub: "solve rate")
            statCard(label: "Time", value: fmtMins(store.minutesToday), sub: "active")
        }
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    /// Group attempts by catalogID (or by title for freeform problems)
    /// so the same problem worked twice doesn't look like a logging bug.
    /// Each group shows the latest attempt's stats + a count badge.
    private var groupedRecentSessions: [(key: String, latest: StoredDrillAttempt, count: Int, totalMinutes: Double)] {
        var buckets: [String: [StoredDrillAttempt]] = [:]
        var order: [String] = []
        for a in store.attempts {
            let key = a.catalogID ?? "freeform:\(a.title)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(a)
        }
        return order.compactMap { key in
            let attempts = buckets[key] ?? []
            guard let latest = attempts.max(by: { $0.startTime < $1.startTime }) else { return nil }
            let total = attempts.reduce(0.0) { $0 + $1.activeSeconds / 60.0 }
            return (key: key, latest: latest, count: attempts.count, totalMinutes: total)
        }
    }

    private var recentAttemptsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT SESSIONS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groupedRecentSessions.prefix(20), id: \.key) { g in
                    groupedAttemptRow(latest: g.latest, count: g.count, totalMinutes: g.totalMinutes)
                }
            }
        }
    }

    private func groupedAttemptRow(latest a: StoredDrillAttempt, count: Int, totalMinutes: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: outcomeIcon(a.outcome))
                .foregroundStyle(outcomeColor(a.outcome))
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(a.title.isEmpty ? a.source : a.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if count > 1 {
                        Text("×\(count)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.16)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(a.source) · \(fmtMins(totalMinutes))" +
                     (a.hintsPeeked > 0 ? " · \(a.hintsPeeked) hint\(a.hintsPeeked == 1 ? "" : "s")" : "") +
                     (a.monteCarloUsed ? " · MC" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(relativeDate(a.startTime))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.05)))
    }

    // MARK: - Active
    //
    // Visual hierarchy follows flow-research:
    //   • In green zone — the timer fades back, quote takes center.
    //     The work is the point, not the clock.
    //   • In yellow — timer grows, coaching line + quote pivot to
    //     "you're in the insight zone" framing.
    //   • In red — timer is prominent, escape valves visually pop.
    //     Time to pivot.

    private var activeView: some View {
        // Three-region layout:
        //   • Top toolbar (pinned)   — nav, source, font controls, PDF
        //   • Scrollable middle      — quote, title, problem, answer, status
        //   • Bottom action panel    — tools + outcomes (pinned)
        //
        // Pinning the toolbar and the action panel means the user never
        // has to scroll to see navigation arrows or the "how did it go?"
        // outcomes, regardless of how long the problem text is.
        VStack(spacing: 0) {
            problemToolbar

            setProgressBar
                .padding(.top, 8)

            pinnedStageStepper
                .padding(.top, 8)
                .padding(.bottom, 10)

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if store.zone != .red {
                        quoteCard
                    }

                    problemTitleRow

                    masteryStatusPill

                    problemBody

                    answerReveal
                        .id("answer-anchor")

                    attemptHistorySection

                    // clockBlock + zoneBar deliberately removed from the
                    // scroll content. The big elapsed-time text + colored
                    // zone progress bar were making the screen feel like a
                    // race against the clock. The compact timerChip pinned
                    // in the top toolbar covers the "is the timer running?"
                    // information need without the pressure.

                    if store.shouldSuggestBreak {
                        burnoutBanner
                    }

                    statusRow
                }
                .padding(.vertical, 12)
            }
            .onChange(of: revealedAnswerID) { _, newValue in
                // When the answer block appears, the user usually can't see
                // it — the problem body pushes it below the fold. Auto-scroll
                // the answer into view. Slight delay lets the layout settle
                // before the proxy measures it.
                guard newValue != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("answer-anchor", anchor: .top)
                    }
                }
            }
            } // ScrollViewReader

            Divider().opacity(0.4)

            actionButtons
                .padding(.top, 10)
        }
        .onChange(of: store.zone) { _, newZone in
            lastZone = newZone
        }
        .onChange(of: store.activeProblem?.id) { _, _ in
            hideAnswer()
        }
    }

    /// Pinned top toolbar — nav arrows, source label, font scale.
    /// Always visible regardless of how far down the user has scrolled.
    @ViewBuilder
    private var problemToolbar: some View {
        if let p = store.activeProblem {
            HStack(spacing: 6) {
                Button {
                    store.navigatePrevious()
                    hideAnswer()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .iconTarget()
                        .foregroundStyle(store.canNavigatePrevious ? .primary : .tertiary)
                }
                .buttonStyle(.plainHit)
                .disabled(!store.canNavigatePrevious)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous problem (←)")

                Text(p.sourceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)

                Spacer()

                // Persistent timer chip — always visible no matter how long
                // the problem body is. The big clockBlock farther down still
                // shows the zone vibes; this one is just the at-a-glance.
                timerChip

                fontScaleControls

                Button {
                    store.navigateNext()
                    hideAnswer()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .iconTarget()
                        .foregroundStyle(store.canNavigateNext ? .primary : .tertiary)
                }
                .buttonStyle(.plainHit)
                .disabled(!store.canNavigateNext)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next problem (→)")
            }
        }
    }

    /// Position of the active problem inside its parent set, scoped to
    /// kind (homework vs strategic practice). Pinned at the top so the
    /// user always knows "I'm on HW 4 of 7".
    @ViewBuilder
    private var setProgressBar: some View {
        if let p = store.activeProblem,
           let set = Stat110Catalog.problemSet(number: p.setNumber) {
            let sameKind = set.problems.filter { $0.kind == p.kind }
            if let idx = sameKind.firstIndex(where: { $0.id == p.id }), !sameKind.isEmpty {
                let position = idx + 1
                let total = sameKind.count
                let frac = Double(position) / Double(total)
                let kindLabel = p.kind == .homework ? "HW" : "SP"
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(kindLabel) \(position) of \(total)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(set.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(frac * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 4)
                            Capsule()
                                .fill(Color.accentColor.opacity(0.65))
                                .frame(width: max(2, geo.size.width * frac), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    /// Always-visible R1 → R2 → R3 → Retained stepper for the active
    /// problem. Lives in the pinned top so the user never has to scroll
    /// to know what rung they're trying to clear.
    @ViewBuilder
    private var pinnedStageStepper: some View {
        if let p = store.activeProblem {
            let record = masteryStore.record(for: p.id)
            ladderStepperRow(currentStage: record?.stage,
                             dueAt: record?.nextDue)
        }
    }

    /// Reusable 4-segment stepper. Past segments are dimmed in their tint,
    /// current segment is bold + colored, future segments are gray.
    /// Caption line below shows the human-readable status.
    private func ladderStepperRow(currentStage: MasteryStage?,
                                  dueAt: Date?) -> some View {
        let stages: [(MasteryStage, String, Color)] = [
            (.familiarized, "R1", Color.orange),
            (.r1Passed,     "R2", Color.purple),
            (.r2Passed,     "R3", Color.blue),
            (.retained,     "Retained", Color(red: 0.25, green: 0.72, blue: 0.53))
        ]
        let currentIdx: Int = {
            guard let c = currentStage else { return -1 }
            return stages.firstIndex { $0.0 == c } ?? -1
        }()
        let caption: String = {
            guard let stage = currentStage else { return "Not on the ladder yet — first solve anchors at R1." }
            switch stage {
            case .retained:
                return "Retained — no more cold reviews scheduled."
            case .lapsed:
                return "Lapsed — re-familiarize to get back on the ladder."
            case .familiarized, .r1Passed, .r2Passed:
                if let d = dueAt {
                    let delta = d.timeIntervalSinceNow
                    if delta <= 0 { return "Cold review due now." }
                    return "Cold review in \(humanizeInterval(delta)) (\(formatExactDueDate(d)))."
                }
                return "Cold review scheduled."
            }
        }()
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    let isPassed = currentIdx > i
                    let isCurrent = currentIdx == i
                    let tint = s.2
                    let fillOpacity: Double = isCurrent ? 0.85 : (isPassed ? 0.42 : 0.12)
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(tint.opacity(fillOpacity))
                            .frame(height: 6)
                        Text(s.1)
                            .font(.system(size: 9, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(isCurrent ? tint : (isPassed ? tint.opacity(0.75) : .secondary))
                    }
                }
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Compact MM:SS in the pinned toolbar. Intentionally minimal — no
    /// zone color, no progress bar, just elapsed time in neutral gray.
    /// The point is "the timer is running" awareness, not "you're racing
    /// the clock" pressure. A small dot turns hollow when paused so it's
    /// obvious without screaming.
    private var timerChip: some View {
        let zone = store.zone
        let zoneColor = zone.color
        let chipTint = store.isPaused ? Color.gray : zoneColor
        return HStack(spacing: 5) {
            Image(systemName: store.isPaused ? "pause.circle" : "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(chipTint)
            Text(elapsedString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(chipTint.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(chipTint.opacity(0.35), lineWidth: 0.6))
        .help(store.isPaused ? "Paused" : zone.coachingLine)
    }

    /// Title + Copy button — stays in the scrolling region so a long
    /// title can wrap without crowding the pinned toolbar.
    @ViewBuilder
    private var problemTitleRow: some View {
        if let p = store.activeProblem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if p.title.contains("$") || p.title.contains("\\") {
                        AutoSizingMathView(content: p.title, fontSize: 17 * fontScale)
                    } else {
                        Text(p.title)
                            .font(.system(size: 17 * fontScale, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !p.body.isEmpty {
                    copyProblemButton(p)
                }
            }
        }
    }

    /// Read-only status line under the title: where this problem sits on
    /// the mastery ladder, when the next review is due, and how much time
    /// you've spent on it across all attempts. Hidden when there's no
    /// active problem or no history yet.
    @ViewBuilder
    private var masteryStatusPill: some View {
        if let p = store.activeProblem {
            let record = masteryStore.record(for: p.id)
            let attempts = masteryStore.attemptCount(forCatalogID: p.id)
            if attempts > 0 || record != nil {
                let total = masteryStore.totalTime(forCatalogID: p.id)
                let lastWorked = masteryStore.lastAttemptDate(forCatalogID: p.id)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        stageBadge(record: record)
                        Text("·").foregroundStyle(.secondary)
                        Text(dueText(record: record))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.85))
                        if let nextDue = record?.nextDue {
                            Text("(\(formatExactDueDate(nextDue)))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(formatMinSec(total))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(Color.primary.opacity(0.78))
                        Text("\(attempts) attempt\(attempts == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let last = lastWorked {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                            Text("Last worked \(relativeDate(last)) · \(formatExactDueDate(last))")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.28), lineWidth: 0.6))
            }
        }
    }

    /// Compact list of recent attempts on the active problem: date,
    /// duration, outcome icon, and what mastery rung the record was on
    /// after that attempt was applied. Surfaces the work history right
    /// where the user is looking at it.
    @ViewBuilder
    private var attemptHistorySection: some View {
        if let p = store.activeProblem {
            let history = masteryStore.attempts(forCatalogID: p.id, limit: 8)
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("HISTORY")
                            .font(.system(size: 9, weight: .bold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(history.count) most recent")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    VStack(spacing: 3) {
                        ForEach(history, id: \.persistentModelID) { a in
                            historyRow(a)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    private func historyRow(_ a: StoredMasteryAttempt) -> some View {
        let (icon, color, label): (String, Color, String) = {
            switch a.outcome {
            case .coldPass:        return ("checkmark.circle.fill", .green, "Solved solo")
            case .aiAssist:        return ("sparkles", .purple, "Solved w/ AI")
            case .soloFamiliarize: return ("checkmark.circle", .blue, "Familiarized")
            case .coldFail:        return ("moon.zzz.fill", .orange, "Couldn't solve")
            case .skipped:         return ("forward.fill", .gray, "Skipped")
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Text(formatMinSec(a.durationSeconds))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Spacer()
            Text(formatExactDueDate(a.date))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(relativeDate(a.date))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.04)))
    }

    private func stageBadge(record: StoredMasteryRecord?) -> some View {
        let (label, color): (String, Color) = {
            guard let r = record else { return ("First exposure", .blue) }
            switch r.stage {
            case .familiarized: return ("Familiarized", .blue)
            case .r1Passed:     return ("R1 passed", Color(red: 0.40, green: 0.70, blue: 0.45))
            case .r2Passed:     return ("R2 passed", Color(red: 0.30, green: 0.65, blue: 0.55))
            case .retained:     return ("Retained", Color(red: 0.25, green: 0.72, blue: 0.53))
            case .lapsed:       return ("Lapsed", .orange)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }

    private func dueText(record: StoredMasteryRecord?) -> String {
        guard let r = record else { return "Not yet on the ladder" }
        switch r.stage {
        case .retained: return "Graduated — re-read for fun"
        case .lapsed:   return "Lapsed — re-familiarize"
        case .familiarized, .r1Passed, .r2Passed:
            guard let due = r.nextDue else { return "—" }
            let delta = due.timeIntervalSinceNow
            if delta <= 0 { return "Due now" }
            return "Next review in \(humanizeInterval(delta))"
        }
    }

    private func humanizeInterval(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60, rm = m % 60
        if h < 24 { return rm == 0 ? "\(h)h" : "\(h)h \(rm)m" }
        let d = h / 24, rh = h % 24
        return rh == 0 ? "\(d)d" : "\(d)d \(rh)h"
    }

    private func formatMinSec(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return String(format: "%ds", sec)
    }

    private enum OutcomeKind { case familiarize, reviewPass, reviewFail, retained, skip }

    /// Wraps an outcome handler so the post-action mastery state can be
    /// surfaced as a banner. Captures the active problem's catalog id
    /// before the action runs (the active problem is nil afterwards).
    private func runOutcome(_ kind: OutcomeKind, _ action: () -> Void) {
        let pid = store.activeProblem?.id
        action()
        guard let id = pid else { return }
        let rec = masteryStore.record(for: id)
        showOutcomeBanner(makeOutcomeBanner(kind: kind, record: rec))
    }

    private func showOutcomeBanner(_ b: OutcomeBanner) {
        withAnimation(.easeInOut(duration: 0.2)) { outcomeBanner = b }
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if outcomeBanner == b { outcomeBanner = nil }
                }
            }
        }
    }

    private func makeOutcomeBanner(kind: OutcomeKind,
                                   record: StoredMasteryRecord?) -> OutcomeBanner {
        let green = Color(red: 0.20, green: 0.65, blue: 0.40)
        switch kind {
        case .familiarize:
            if let r = record, let due = r.nextDue, r.familiarizationCount <= 1 {
                return OutcomeBanner(
                    title: "Familiarized — R1 cold review scheduled",
                    detail: "Due \(humanizeInterval(due.timeIntervalSinceNow)) from now — \(formatExactDueDate(due)).",
                    icon: "checkmark.circle.fill",
                    color: .blue)
            }
            if let r = record, r.familiarizationCount > 1 {
                let scheduleNote: String
                if let due = r.nextDue {
                    scheduleNote = "Next review still \(formatExactDueDate(due))."
                } else {
                    scheduleNote = "Schedule unchanged."
                }
                return OutcomeBanner(
                    title: "Re-familiarization logged",
                    detail: "\(scheduleNote) Time tracked across attempts.",
                    icon: "clock.arrow.circlepath",
                    color: .blue)
            }
            return OutcomeBanner(title: "Logged",
                                 detail: "Familiarization tracked.",
                                 icon: "checkmark",
                                 color: .blue)
        case .reviewPass:
            guard let r = record else {
                return OutcomeBanner(title: "Passed",
                                     detail: "Tracked.",
                                     icon: "checkmark.seal.fill",
                                     color: green)
            }
            let whenText: String = r.nextDue.map { d in
                "\(humanizeInterval(d.timeIntervalSinceNow)) from now — \(formatExactDueDate(d))"
            } ?? "soon"
            switch r.stage {
            case .r1Passed:
                return OutcomeBanner(title: "R1 passed → R2 scheduled",
                                     detail: "Next cold pass \(whenText).",
                                     icon: "checkmark.seal.fill", color: green)
            case .r2Passed:
                return OutcomeBanner(title: "R2 passed → R3 scheduled",
                                     detail: "Next cold pass \(whenText).",
                                     icon: "checkmark.seal.fill", color: green)
            case .retained:
                return OutcomeBanner(title: "Retained!",
                                     detail: "Graduated — no more cold reviews scheduled.",
                                     icon: "trophy.fill", color: green)
            case .familiarized:
                // First cold pass on a re-familiarized lapsed problem.
                return OutcomeBanner(title: "Cold pass logged",
                                     detail: "R1 review scheduled \(whenText).",
                                     icon: "checkmark.seal.fill", color: green)
            case .lapsed:
                return OutcomeBanner(title: "Passed",
                                     detail: "Tracked.",
                                     icon: "checkmark.seal.fill", color: green)
            }
        case .reviewFail:
            return OutcomeBanner(
                title: "Marked lapsed",
                detail: "Stage dropped. Pick it up again any time — the next familiarization will re-schedule R1.",
                icon: "exclamationmark.triangle.fill",
                color: .orange)
        case .retained:
            return OutcomeBanner(
                title: "Marked retained",
                detail: "Skipped the ladder. No more cold reviews scheduled for this problem.",
                icon: "trophy.fill",
                color: green)
        case .skip:
            return OutcomeBanner(title: "Skipped",
                                 detail: "No schedule change.",
                                 icon: "forward.fill",
                                 color: .gray)
        }
    }

    /// Absolute due date — short form like "Mon 3pm" for tomorrow,
    /// "Fri Dec 5" for further out. Surfaced next to the relative
    /// countdown so the user can plan around it.
    private func formatExactDueDate(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) {
            f.dateFormat = "'today' h:mm a"
        } else if cal.isDateInTomorrow(d) {
            f.dateFormat = "'tomorrow' h:mm a"
        } else if let days = cal.dateComponents([.day], from: Date(), to: d).day, days < 7 {
            f.dateFormat = "EEE h:mm a"
        } else {
            f.dateFormat = "EEE MMM d"
        }
        return f.string(from: d)
    }

    /// Small clipboard button next to the problem title. Copies the full
    /// problem body as plain text so the user can paste it into an external
    /// AI chat (ChatGPT, Claude, etc.) for hint-style help that doesn't
    /// leak through the in-app answer reveal.
    @ViewBuilder
    private func copyProblemButton(_ p: Stat110Problem) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(p.body, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copiedProblem = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.2)) { copiedProblem = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedProblem ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copiedProblem ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(copiedProblem ? Color.green : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill((copiedProblem ? Color.green : Color.gray).opacity(0.10))
            )
        }
        .buttonStyle(.plainHit)
        .help("Copy the problem text — paste into an AI chat for hints")
    }

    /// A−  /  A+  buttons in the header. Adjusts the practice-mode font
    /// scale, persisted via @AppStorage. Clamps to a sensible range.
    private var fontScaleControls: some View {
        HStack(spacing: 2) {
            Button {
                fontScale = max(0.8, fontScale - 0.1)
            } label: {
                Text("A−")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHit)
            .keyboardShortcut("-", modifiers: .command)
            .help("Smaller text (⌘−)")

            Button {
                fontScale = min(1.6, fontScale + 0.1)
            } label: {
                Text("A+")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plainHit)
            .keyboardShortcut("=", modifiers: .command)
            .help("Larger text (⌘=)")
        }
        .foregroundStyle(.secondary)
    }

/// The problem statement itself — serif, scrollable when long. Preserves
    /// the user's flow: read here, hint here, move on, all without leaving.
    @ViewBuilder
    private var problemBody: some View {
        if let p = store.activeProblem, !p.body.isEmpty {
            AutoSizingMathView(content: p.body, fontSize: 13 * fontScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.10)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.22), lineWidth: 0.7)
                )
        } else if let p = store.activeProblem {
            // Catalog problem without transcribed body — fall back to a
            // small notice + PDF link. (HW2/HW3 are populated; later
            // problem sets may not be yet.)
            VStack(spacing: 4) {
                Text("Problem text not yet transcribed in-app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let url = problemURL(p) {
                    Link("Open PDF", destination: url).font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.05)))
        }
    }

    /// Answer reveal — single block, rendered with KaTeX. Shows only when
    /// the user explicitly asks. Replaces the old progressive hint reveal,
    /// which was leaking method information (the point is to figure out
    /// the *approach* yourself; the answer is for self-checking).
    @ViewBuilder
    private var answerReveal: some View {
        if isAnswerRevealed, let p = store.activeProblem, !p.answer.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.green)
                    Text("Answer")
                        .font(.system(size: 10 * fontScale, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { hideAnswer() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9 * fontScale, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .iconTarget()
                    }
                    .buttonStyle(.plainHit)
                    .padding(-12)
                    .help("Hide the answer")
                }
                AutoSizingMathView(content: p.answer, fontSize: 14 * fontScale)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.22), lineWidth: 0.5))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Clock + zone label. Size and prominence scale with zone — in green
    /// it's subtle, in red it's the main element. This is intentional:
    /// timer-as-centerpiece creates time anxiety in flow zones.
    private var clockBlock: some View {
        let size: CGFloat = {
            switch store.zone {
            case .green:  return 36
            case .yellow: return 48
            case .red:    return 60
            }
        }()
        let weight: Font.Weight = (store.zone == .red) ? .regular : .ultraLight
        return VStack(spacing: 6) {
            Text(elapsedString)
                .font(.system(size: size, weight: weight, design: .monospaced))
                .foregroundStyle(store.zone.color.opacity(store.zone == .green ? 0.75 : 1.0))
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: elapsedString)
                .animation(.easeInOut(duration: 0.4), value: store.zone)

            Text(store.zone.label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(store.zone.color)

            Text(coachingLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(minHeight: 28)
                .animation(.easeInOut(duration: 0.4), value: store.zone)
        }
        .padding(.vertical, store.zone == .green ? 4 : 10)
    }

    /// Coaching line — rewritten from the Zone helper to be more
    /// permission-granting + specific. Pulled here so it can adapt
    /// based on hint count etc. without touching the FocusCore enum.
    private var coachingLine: String {
        switch store.zone {
        case .green:
            return "Settle in. Read the problem twice. Define your variables."
        case .yellow:
            return "You've thought deeply for 15 minutes. Most insights show up in the next 5."
        case .red:
            if store.hintsPeeked == 0 && !store.monteCarloUsed {
                return "Time to pivot. A first-line peek isn't giving up — it's the move."
            } else if store.monteCarloUsed {
                return "You ran the sim. What pattern does the empirical answer suggest?"
            } else {
                return "You took the nudge. Run with it. That's the muscle you're building."
            }
        }
    }

    /// The quote card. Serif, soft cream background. Stable per problem —
    /// the seed is derived from the problem ID so the same problem
    /// always shows the same quote, no churn during a session.
    private var quoteCard: some View {
        // Single quote per day, period. Don't switch contexts as the zone
        // changes (general → yellow → red) — that was churning the quote
        // mid-session, which contradicts the once-a-day promise. The
        // zone-specific encouragement now lives only in `coachingLine`.
        let q = PracticeQuotes.daily(.general)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("\u{201C}")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(store.zone.color.opacity(0.45))
                    .padding(.top, 2)
                Text(q.text)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !q.author.isEmpty {
                Text("— \(q.author)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(store.zone.color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(store.zone.color.opacity(0.15), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Counters + status, but rendered as a single line of subtle text
    /// instead of three big chips that dominated the old design. The
    /// signal is here when you want it, but doesn't compete for attention.
    private var statusRow: some View {
        HStack(spacing: 14) {
            statusItem(icon: "lightbulb",
                       label: store.hintsPeeked == 0 ? "no hints yet" :
                              "\(store.hintsPeeked) hint\(store.hintsPeeked == 1 ? "" : "s")")
            statusItem(icon: "function",
                       label: store.monteCarloUsed ? "MC used" : "no sim yet")
            statusItem(icon: store.isPaused ? "pause.circle" : "circle.fill",
                       label: store.isPaused ? "paused" : "running",
                       tint: store.isPaused ? .orange : .green)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func statusItem(icon: String, label: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
                .foregroundStyle(tint)
            Text(label)
        }
    }

    private var zoneBar: some View {
        GeometryReader { geo in
            let total: TimeInterval = 30 * 60
            let frac = min(1.0, store.elapsedSeconds / total)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.12))
                    .frame(height: 6)
                HStack(spacing: 0) {
                    Capsule().fill(PracticeStore.Zone.green.color.opacity(0.5))
                        .frame(width: geo.size.width * (15.0 / 30.0), height: 6)
                    Capsule().fill(PracticeStore.Zone.yellow.color.opacity(0.5))
                        .frame(width: geo.size.width * (5.0 / 30.0), height: 6)
                    Capsule().fill(PracticeStore.Zone.red.color.opacity(0.5))
                        .frame(width: geo.size.width * (10.0 / 30.0), height: 6)
                }
                Capsule().fill(store.zone.color)
                    .frame(width: geo.size.width * frac, height: 6)
                    .animation(.linear(duration: 0.5), value: frac)
            }
        }
        .frame(height: 6)
    }

    private var burnoutBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
            Text("\(store.burstCount) sessions in this burst. Consider a 10-min walk after this one.")
                .font(.system(size: 11))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func counterChip(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium)).tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    // MARK: - Action panel
    //
    // Reorganized into two clearly-separated groups:
    //   • Tools (smaller, secondary): pause / show answer / Monte Carlo —
    //     things you do *during* the session.
    //   • Outcomes (bigger, decisive): how this session *ends* — Solved,
    //     Walked-with-AI, Stuck. The user's main complaint was that the
    //     interface didn't signal which buttons mattered most. The
    //     outcome group is now visually heavier than the tool group.

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolStrip
            outcomeGroup
        }
    }

    /// Mid-session tools — compact icon strip, secondary in the hierarchy.
    /// Show-Answer and Monte Carlo are always available now; the
    /// familiarization/review split was hiding the answer behind a mode
    /// switch that didn't match how the user actually works.
    private var toolStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tools")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    store.isPaused ? store.resume() : store.pause()
                } label: {
                    toolChip(icon: store.isPaused ? "play.fill" : "pause.fill",
                             label: store.isPaused ? "Resume" : "Pause",
                             tint: .secondary)
                }
                .buttonStyle(.plainHit)

                Button {
                    toggleAnswer()
                } label: {
                    toolChip(icon: isAnswerRevealed ? "checkmark.seal.fill" : "checkmark.seal",
                             label: isAnswerRevealed ? "Hide answer" : "Show answer",
                             tint: .secondary)
                }
                .buttonStyle(.plainHit)
                .help(answerButtonHelp)
                .disabled(answerButtonDisabled)

                Button {
                    showMonteCarloSheet = true
                } label: {
                    toolChip(icon: "function", label: "Monte Carlo", tint: .secondary)
                }
                .buttonStyle(.plainHit)
                .help("Monte Carlo: simulate the problem in code (e.g. 100,000 random trials in Python) to estimate the answer numerically.")
            }
        }
    }

    private func toolChip(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.25), lineWidth: 0.7))
        .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.78) : tint)
    }

    /// Unified outcome group — same three buttons whether this is a fresh
    /// familiarization or a cold review. The ladder rule is now driven by
    /// `usedAI` rather than by a separate mode the user has to opt into:
    ///
    ///   • Solved solo   → advance one rung (or anchor at R1 if untouched)
    ///   • Solved w/ AI  → log time; anchor at R1 if untouched, else hold
    ///   • Couldn't      → log time; hold the rung, push nextDue +24h
    ///
    /// Below the buttons sits the manual ladder picker, which lets the
    /// user override the stage directly.
    @ViewBuilder
    private var outcomeGroup: some View {
        if let p = store.activeProblem {
            VStack(alignment: .leading, spacing: 10) {
                outcomeHeader
                outcomeButton(
                    action: {
                        runOutcome(.reviewPass) {
                            store.finishSolved(usedAI: false, notes: "")
                        }
                    },
                    icon: "checkmark.circle.fill",
                    title: "Solved without AI",
                    subtitle: solvedSoloSubtitle(for: p),
                    tint: Color.green
                )

                outcomeButton(
                    action: {
                        runOutcome(.familiarize) {
                            store.finishSolved(usedAI: true, notes: "")
                        }
                    },
                    icon: "sparkles",
                    title: "Solved with AI",
                    subtitle: solvedAISubtitle(for: p),
                    tint: Color.purple
                )

                outcomeButton(
                    action: { runOutcome(.reviewFail) { store.finishStuck(notes: "") } },
                    icon: "moon.zzz.fill",
                    title: "Couldn't get there",
                    subtitle: "Logs time. Stays at the current rung; next review +24h.",
                    tint: Color.orange
                )

                manualStagePicker(for: p)

                HStack {
                    if store.isInReviewSession {
                        Button("Skip this one") {
                            runOutcome(.skip) { store.finishSkipped(notes: "") }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.plainHit)
                    }
                    Spacer()
                    Button(store.isInReviewSession ? "End review session" : "Discard") {
                        store.discardActive()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plainHit)
                }
            }
        }
    }

    /// Tiny header row — shows the queue position when inside a review
    /// session, otherwise just the section label.
    private var outcomeHeader: some View {
        HStack(spacing: 6) {
            Text("Outcome")
                .font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(.tertiary)
            Spacer()
            if store.isInReviewSession {
                Text("\(store.reviewQueueIndex + 1) / \(store.reviewQueue.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Subtitle for the "Solved without AI" button — depends on where the
    /// problem currently sits on the ladder, so the user sees what the
    /// click will do.
    private func solvedSoloSubtitle(for p: Stat110Problem) -> String {
        guard let r = masteryStore.record(for: p.id) else {
            return "Anchors at R1 (review in 24h)."
        }
        switch r.stage {
        case .familiarized: return "Promotes R1 → R2 (review in \(r.r2IntervalDays) days)."
        case .r1Passed:     return "Promotes R2 → R3 (review in 7 days)."
        case .r2Passed:     return "Promotes R3 → Retained. No more reviews."
        case .retained:     return "Already retained — bonus pass."
        case .lapsed:       return "Re-anchors at R1 (review in 24h)."
        }
    }

    private func solvedAISubtitle(for p: Stat110Problem) -> String {
        guard let r = masteryStore.record(for: p.id) else {
            return "Anchors at R1 (review in 24h)."
        }
        switch r.stage {
        case .familiarized: return "Promotes R1 → R2 (review in \(r.r2IntervalDays) days)."
        case .r1Passed:     return "Holds at R2 — AI can't take you to R3."
        case .r2Passed:     return "Holds at R3 — Retained needs a solo solve."
        case .retained:     return "Logged. Stays retained."
        case .lapsed:       return "Re-anchors at R1 (review in 24h)."
        }
    }

    /// Manual ladder picker — five chips for the four "live" stages plus a
    /// "remove from ladder" button. Tapping a chip pins the active problem
    /// to that stage (with the canonical interval) and ends the attempt.
    @ViewBuilder
    private func manualStagePicker(for p: Stat110Problem) -> some View {
        let current = masteryStore.record(for: p.id)?.stage
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Manual override")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                if current != nil {
                    Button("Remove from ladder") {
                        store.removeFromLadder()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plainHit)
                    .help("Wipe this problem's ladder record entirely. Past attempts in the audit log are kept.")
                }
            }
            HStack(spacing: 4) {
                stageChip(target: .familiarized, label: "R1 · 24h", current: current)
                stageChip(target: .r1Passed,     label: "R2 · 2–3d", current: current)
                stageChip(target: .r2Passed,     label: "R3 · 7d",  current: current)
                stageChip(target: .retained,     label: "Retained", current: current)
            }
        }
        .padding(.top, 4)
    }

    private func stageChip(target: MasteryStage, label: String, current: MasteryStage?) -> some View {
        let isCurrent = (current == target)
        let tint: Color = {
            switch target {
            case .familiarized: return .orange
            case .r1Passed:     return .purple
            case .r2Passed:     return .blue
            case .retained:     return .green
            case .lapsed:       return .red.opacity(0.7)
            }
        }()
        return Button {
            store.setStageManually(target)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(isCurrent ? 0.30 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(isCurrent ? 0.7 : 0.25), lineWidth: isCurrent ? 1.0 : 0.5)
                )
                .foregroundStyle(tint)
        }
        .buttonStyle(.plainHit)
        .help(isCurrent ? "Currently at this stage" : "Pin to \(label)")
    }

    private func outcomeButton(action: @escaping () -> Void,
                               icon: String,
                               title: String,
                               subtitle: String,
                               tint: Color) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(tint.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(tint.opacity(0.45), lineWidth: 0.8)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plainHit)
    }

    private var nudgeColor: Color {
        switch store.zone {
        case .green:  return .secondary
        case .yellow: return PracticeStore.Zone.yellow.color
        case .red:    return PracticeStore.Zone.red.color
        }
    }

    // MARK: - Answer reveal

    /// True only when the reveal is keyed to the currently-active problem.
    /// If the user navigates away, `revealedAnswerID` no longer matches
    /// and this flips to false automatically — no race against `.onChange`.
    private var isAnswerRevealed: Bool {
        guard let id = store.activeProblem?.id else { return false }
        return revealedAnswerID == id
    }

    private func hideAnswer() { revealedAnswerID = nil }

    private var answerButtonDisabled: Bool {
        guard let p = store.activeProblem else { return true }
        return p.answer.isEmpty
    }

    private var answerButtonHelp: String {
        guard let p = store.activeProblem else { return "" }
        if p.answer.isEmpty { return "Answer not yet transcribed for this problem" }
        return isAnswerRevealed ? "Collapse the answer" : "Show the final answer from the Stat 110 handout"
    }

    private func toggleAnswer() {
        guard let p = store.activeProblem, !p.answer.isEmpty else { return }
        if !isAnswerRevealed {
            store.peekHint()   // count the first reveal for stats
            withAnimation(.easeInOut(duration: 0.2)) { revealedAnswerID = p.id }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { hideAnswer() }
        }
    }

    // MARK: - Helpers

    private var elapsedString: String {
        let s = Int(store.elapsedSeconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func problemURL(_ p: Stat110Problem) -> URL? {
        guard let set = Stat110Catalog.problemSet(number: p.setNumber) else { return nil }
        return URL(string: set.pdfURL)
    }

    private func outcomeIcon(_ o: DrillOutcome) -> String {
        switch o {
        case .solved:         return "checkmark.circle.fill"
        case .aiWalkthrough:  return "sparkles"
        case .stuck:          return "exclamationmark.circle"
        case .skipped:        return "arrow.right.circle"
        }
    }

    private func outcomeColor(_ o: DrillOutcome) -> Color {
        switch o {
        case .solved:         return .green
        case .aiWalkthrough:  return .purple
        case .stuck:          return .orange
        case .skipped:        return .secondary
        }
    }

    private func confidenceIcon(_ c: Confidence) -> String {
        switch c {
        case .solid:     return "checkmark.seal.fill"
        case .shaky:     return "questionmark.circle"
        case .struggled: return "exclamationmark.triangle.fill"
        }
    }

    private func confidenceColor(_ c: Confidence) -> Color {
        switch c {
        case .solid:     return .green
        case .shaky:     return .orange
        case .struggled: return .red
        }
    }

    private func fmtMins(_ m: Double) -> String {
        let total = Int(m * 60)
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}


// MARK: - Monte Carlo sheet

private struct MonteCarloSheet: View {
    @ObservedObject var store: PracticeStore
    @Binding var isPresented: Bool
    @State private var copied = false

    private let template: String = """
    # Monte Carlo template — formalize the rules, then simulate.
    # Goal: when the closed-form math is opaque, let empirical
    # structure reveal it. Print the running average; if it
    # converges to a clean fraction, you've found the answer.
    import random

    TRIALS = 100_000

    def run_one_trial():
        # TODO: encode ONE play of the random process here.
        # Return True if the event you care about happened.
        return random.random() < 0.5

    hits = sum(run_one_trial() for _ in range(TRIALS))
    p = hits / TRIALS
    print(f"P(event) ≈ {p:.5f}   ({hits}/{TRIALS})")
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monte Carlo — simulate the problem")
                .font(.system(size: 18, weight: .semibold))
            Text("**What this is:** instead of solving for the answer in closed form, write the rules of the problem as code and run it many times (e.g. 100,000 trials in Python). The empirical fraction of successes approximates the true probability — if it converges to something clean like 0.286, you've spotted 2/7.\n\n**Why it helps:** the act of formalizing the rules often makes the math obvious. And it gives you a number to *aim* your closed-form derivation at.\n\nCopy this template, fill in `run_one_trial`, run it locally. We'll mark this session as having used MC for stats.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(template)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))

            HStack {
                Button(copied ? "Copied!" : "Copy template") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(template, forType: .string)
                    copied = true
                    store.markMonteCarlo()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                }
                Spacer()
                Button("Done") {
                    store.markMonteCarlo()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Problem picker

private struct PracticeProblemPicker: View {
    @ObservedObject var homeworkStore: HomeworkStore
    @Binding var isPresented: Bool
    let onPick: (Stat110Problem) -> Void

    @State private var query: String = ""
    @State private var expandedSets: Set<Int> = Set(Stat110Catalog.all.map(\.setNumber))

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick a problem to practice")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { isPresented = false }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Stat110Catalog.all) { set in
                        let problems = filteredProblems(set)
                        if !problems.isEmpty {
                            let isExpanded = expandedSets.contains(set.setNumber) || !query.isEmpty
                            Button {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if expandedSets.contains(set.setNumber) {
                                        expandedSets.remove(set.setNumber)
                                    } else {
                                        expandedSets.insert(set.setNumber)
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                    Text(set.title).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("\(problems.count)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plainHit)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }

                            if isExpanded {
                                LazyVStack(spacing: 0) {
                                    ForEach(problems) { p in
                                        Button {
                                            onPick(p)
                                            isPresented = false
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Text(p.kind == .homework ? "HW \(p.number)" : "SP \(p.number)")
                                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 56, alignment: .leading)
                                                    .padding(.top, 2)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    if p.title.contains("$") || p.title.contains("\\") {
                                                        AutoSizingMathView(content: p.title, fontSize: 12)
                                                    } else {
                                                        Text(p.title)
                                                            .font(.system(size: 12))
                                                            .multilineTextAlignment(.leading)
                                                    }
                                                    if let t = p.topic {
                                                        Text(t).font(.system(size: 10)).foregroundStyle(.tertiary)
                                                    }
                                                }
                                                Spacer()
                                                if let hw = homeworkStore.items.first(where: { $0.catalogID == p.id }) {
                                                    statusPill(hw)
                                                }
                                            }
                                            .padding(.vertical, 7).padding(.horizontal, 16)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plainHit)
                                        .onHover { hovering in
                                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                        }
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 560, height: 620)
    }

    @ViewBuilder
    private func statusPill(_ hw: HomeworkProblem) -> some View {
        let (label, color): (String, Color) = {
            if hw.isDueForReview { return ("Due", .orange) }
            switch hw.confidence {
            case .solid:     return ("✓", .green)
            case .shaky:     return ("Shaky", .orange)
            case .struggled: return ("Struggled", .red)
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func filteredProblems(_ set: Stat110ProblemSet) -> [Stat110Problem] {
        guard !query.isEmpty else { return set.problems }
        let q = query.lowercased()
        return set.problems.filter {
            $0.title.lowercased().contains(q)
                || ($0.topic?.lowercased().contains(q) ?? false)
                || $0.number.contains(q)
        }
    }
}
