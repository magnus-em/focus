import AppKit
import Combine
import SwiftUI
import FocusCore

@MainActor
final class LeetCodeSolveDraftStore: ObservableObject {
    struct Draft {
        let candidate: LeetCodeSolveEvidence.Candidate
        let problem: LCProblem
        let minutes: Int?
    }
    private static weak var visible: LeetCodeSolveDraftStore?
    nonisolated static var isShowing: Bool { MainActor.assumeIsolated { visible?.panel != nil } }
    @Published private(set) var current: Draft?
    @Published private(set) var error: String?
    private weak var store: LeetCodeStore?
    private var subscription: AnyCancellable?
    private var panel: NSPanel?
    private var timer: Timer?
    private var expires: Date?
    private var pending: [Draft] = []
    private static let seenKey = "leetcode.solveDraftsSeen"
    private var seen: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue,forKey:Self.seenKey) }
    }

    init(store: LeetCodeStore) {
        self.store = store
        subscription = ScreenJournalStore.shared.didStore.sink { [weak self] in self?.observe($0) }
        timer = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in Task { @MainActor in self?.showNext() } }
    }
    private func observe(_ row: ScreenJournal.Row) {
        guard let store, let text = row.text, ScreenWatcher.userIgnored[row.bundle] == nil,
              let candidate = LeetCodeSolveEvidence.candidate(row:row,text:text), Calendar.current.isDateInToday(candidate.observedAt),
              seen[candidate.dailyKey] == nil, !pending.contains(where:{$0.candidate.dailyKey == candidate.dailyKey}),
              current?.candidate.dailyKey != candidate.dailyKey,
              !store.today.contains(where:{$0.problem.slug == candidate.slug}),
              let problem = store.catalog.problem(slug:candidate.slug), pending.count < 5 else { return }
        let minutes = LeetCodeSolveEvidence.stopwatchMinutes(slug:candidate.slug,activeSlug:store.activeSlug,
            startedAt:store.activeStart,observedAt:candidate.observedAt)
        pending.append(Draft(candidate:candidate,problem:problem,minutes:minutes))
        showNext()
    }
    private func showNext() {
        if let expires, expires <= Date() { dismiss() }
        guard panel == nil, !pending.isEmpty, !(ScreenCoach.shared?.isBusy ?? false), !(AwayCoach.shared?.isBusy ?? false) else { return }
        let draft = pending.removeFirst()
        guard Calendar.current.isDateInToday(draft.candidate.observedAt),
              !(store?.today.contains(where:{$0.problem.slug == draft.problem.slug}) ?? true) else { return }
        current = draft; error = nil
        var history = seen
        history[draft.candidate.dailyKey] = "offered"
        let keys = Set(history.keys.sorted().suffix(500)); history = history.filter { keys.contains($0.key) }
        seen = history
        let host = NSHostingView(rootView: LeetCodeDraftPanelContent(drafts:self))
        host.focusRingType = .none
        let size = host.fittingSize
        let panel = SolveDraftPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.nonactivatingPanel,.fullSizeContentView,.borderless],backing:.buffered,defer:false)
        panel.contentView = host; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.level = .floating; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        if let frame = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x:frame.maxX-size.width-16,y:frame.maxY-size.height-12)) }
        self.panel = panel; Self.visible = self; expires = Date().addingTimeInterval(900)
        panel.orderFrontRegardless()
    }
    func confirm(confidence: Confidence, usedHelp: Bool) {
        guard let store, let current, Calendar.current.isDateInToday(current.candidate.observedAt) else { dismiss(); return }
        guard !store.today.contains(where:{$0.problem.slug == current.problem.slug}) else { dismiss(); return }
        guard store.log(current.problem,confidence:confidence,minutes:current.minutes,usedHelp:usedHelp,
            notes:"Confirmed from Accepted submission \(current.candidate.submissionID).",at:current.candidate.observedAt) else {
            error = "Couldn't save the solve. Try again."
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, let view = panel.contentView else { return }
                view.layoutSubtreeIfNeeded()
                panel.setContentSize(view.fittingSize)
            }
            return
        }
        var history = seen; history[current.candidate.dailyKey] = "confirmed"; seen = history
        dismiss()
    }
    func dismiss() {
        panel?.close(); panel = nil; current = nil; expires = nil; error = nil
        if Self.visible === self { Self.visible = nil }
    }
}

private final class SolveDraftPanel: NSPanel { override var canBecomeKey: Bool { true } }

private struct LeetCodeDraftPanelContent: View {
    @ObservedObject var drafts: LeetCodeSolveDraftStore
    var body: some View {
        if let draft = drafts.current {
            LeetCodeSolveDraftCard(title:draft.problem.title,minutes:draft.minutes,error:drafts.error,
                confirm:{ drafts.confirm(confidence:$0,usedHelp:$1) },dismiss:{ drafts.dismiss() })
        }
    }
}

struct LeetCodeSolveDraftCard: View {
    let title: String
    let minutes: Int?
    var error: String? = nil
    let confirm: (Confidence, Bool) -> Void
    let dismiss: () -> Void
    @State private var confidence: Confidence?
    @State private var usedHelp = false
    @Environment(\.colorScheme) private var scheme

    init(title: String, minutes: Int?, error: String? = nil, previewConfidence: Confidence? = nil,
         confirm: @escaping (Confidence, Bool) -> Void, dismiss: @escaping () -> Void) {
        self.title = title; self.minutes = minutes; self.error = error; self.confirm = confirm; self.dismiss = dismiss
        _confidence = State(initialValue: previewConfidence)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Your solve today?",systemImage:"checkmark.circle").font(.system(size:15,weight:.semibold))
                Spacer()
                Button(action:dismiss) { Image(systemName:"xmark").frame(width:36,height:36) }
                    .buttonStyle(.plain).help("Dismiss without logging").accessibilityLabel("Dismiss solve draft")
                    .keyboardShortcut(.cancelAction)
            }
            Text(title).font(.system(size:14,weight:.semibold)).lineLimit(2)
            Text("Accepted submission spotted. Confirm only if you solved this today.")
                .font(.system(size:12)).foregroundStyle(Color.secondaryText)
            Text(minutes.map { "\($0) min from your LeetCode stopwatch" } ?? "Solve time: unknown")
                .font(.system(size:12)).foregroundStyle(Color.secondaryText)
            Text("How did it feel?").font(.system(size:12)).foregroundStyle(Color.secondaryText)
            HStack(spacing:8) {
                ForEach(Confidence.allCases,id:\.self) { choice in
                    Button { confidence = choice } label: {
                        Text(choice.rawValue).frame(maxWidth:.infinity,minHeight:36)
                    }
                    .buttonStyle(.plain)
                    .background(confidence == choice ? categoryColor("SWE").opacity(0.2) : Color.primary.opacity(0.06),in:Capsule())
                    .accessibilityAddTraits(confidence == choice ? .isSelected : [])
                }
            }
            Toggle("Used hints or AI",isOn:$usedHelp)
            if let error { Text(error).font(.system(size:12)).foregroundStyle(.orange) }
            HStack {
                Button("Not my solve",action:dismiss).buttonStyle(.bordered)
                Spacer()
                Button {
                    if let confidence { confirm(confidence,usedHelp) }
                } label: {
                    Text("Log my solve").foregroundStyle(confidence == nil ? Color.secondaryText : scheme == .dark ? .white : .black)
                }
                .buttonStyle(.borderedProminent).tint(categoryColor("SWE"))
                .disabled(confidence == nil).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .font(.system(size:13)).padding(16).frame(width:340,height:410,alignment:.topLeading).modifier(SolveDraftGlass()).focusEffectDisabled()
    }
}

private struct SolveDraftGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius:22,style:.continuous)
        if #available(macOS 26.0,*) { content.glassEffect(.regular,in:shape) }
        else { content.background(.regularMaterial).clipShape(shape) }
    }
}
