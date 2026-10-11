import SwiftUI
import AppKit
import FocusCore

let recallPurple = Color(red: 0.55, green: 0.42, blue: 0.92)

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Corner card shown when a focus block ends: write the most important
/// thing you learned from memory, optionally get Claude's check and cards.
/// Never takes keyboard focus on its own — click into it to type.
final class RecallPanel {
    static let shared = RecallPanel()

    private var panel: NSPanel?
    private var model: RecallPanelModel?
    private var idleWork: DispatchWorkItem?
    private static let width: CGFloat = 380

    func show(session: WorkSession, store: RecallStore, settings: AppSettings) {
        if let model, !model.text.isEmpty || model.stage != .write { return }
        dismiss()

        let m = RecallPanelModel(session: session, store: store)
        m.onClose = { [weak self] in self?.dismiss() }
        m.onActivity = { [weak self] in self?.idleWork?.cancel() }
        m.onResize = { [weak self] h in self?.resize(to: h) }
        model = m

        let host = NSHostingController(rootView: RecallPanelView(model: m))
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 236),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        p.contentViewController = host
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        resize(to: 236)
        p.orderFrontRegardless()

        // An untouched prompt goes away on its own rather than sitting over work all afternoon.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let m = self.model, m.text.isEmpty, m.stage == .write else { return }
            self.dismiss()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 * 60, execute: work)
    }

    private func resize(to height: CGFloat) {
        guard let p = panel, let screen = NSScreen.main?.visibleFrame else { return }
        let frame = NSRect(x: screen.maxX - Self.width - 16, y: screen.maxY - height - 12,
                           width: Self.width, height: height)
        p.setFrame(frame, display: true, animate: p.isVisible)
    }


    func dismiss() {
        idleWork?.cancel()
        idleWork = nil
        panel?.close()
        panel = nil
        model = nil
    }
}

final class RecallPanelModel: ObservableObject {
    enum Stage: Equatable { case write, thinking, review, manualCard, error(String) }

    let session: WorkSession
    let store: RecallStore
    @Published var text = "" { didSet { onActivity?() } }
    @Published var stage: Stage = .write { didSet { onResize?(height) } }
    @Published var feedback = ""
    @Published var drafts: [RecallCardDraft] = []
    @Published var manualPrompt = ""
    @Published var manualAnswer = ""
    private var note: StoredRecallNote?

    var onClose: (() -> Void)?
    var onActivity: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

    init(session: WorkSession, store: RecallStore) {
        self.session = session
        self.store = store
    }

    var course: String { session.label ?? "" }

    var height: CGFloat {
        switch stage {
        case .write: return 236
        case .thinking: return 150
        case .review: return drafts.isEmpty ? 220 : min(560, 190 + CGFloat(drafts.count) * 120)
        case .manualCard: return 330
        case .error: return 170
        }
    }

    func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { onClose?(); return }
        note = store.addNote(kind: .session, text: t, label: course,
                             sessionStart: session.startTime, minutes: session.durationMinutes)
        if RecallCoach.isConfigured {
            stage = .thinking
            askClaude()
        } else {
            manualAnswer = t
            stage = .manualCard
        }
    }

    private func askClaude() {
        let t = text, course = course, minutes = session.durationMinutes
        Task { @MainActor in
            do {
                let r = try await RecallCoach.reviewNote(t, course: course, minutes: minutes)
                if let note { store.setFeedback(note, r.feedback) }
                feedback = r.feedback
                drafts = r.cards
                stage = .review
            } catch {
                stage = .error(error.localizedDescription)
            }
        }
    }

    func addDrafts() {
        store.addDrafts(drafts, course: course, noteID: note?.id)
        onClose?()
    }

    func addManual() {
        store.addItem(course: course, prompt: manualPrompt, answer: manualAnswer, noteID: note?.id)
        onClose?()
    }
}

private struct RecallPanelView: View {
    @ObservedObject var model: RecallPanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.stage {
            case .write: writeStage
            case .thinking: thinkingStage
            case .review: reviewStage
            case .manualCard: manualStage
            case .error(let msg): errorStage(msg)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recallPurple)
            Text(model.course.isEmpty ? "Focus" : model.course)
                .font(.system(size: 12, weight: .semibold))
            Text("· \(Int(model.session.durationMinutes))m")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Skip")
        }
    }

    private var writeStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Without looking at your notes — what's the most important thing you just learned or figured out?")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .focused($focused)
                .frame(height: 96)
            HStack {
                Text(RecallCoach.isConfigured ? "⌘↩ save · Claude checks it" : "⌘↩ save")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Skip") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                Button("Save") { model.save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(recallPurple)
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var thinkingStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude is checking your recall…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("Saved. You can close this; feedback is kept with the note.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Close") { model.onClose?() }.controlSize(.small) }
        }
    }

    private var reviewStage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.feedback.isEmpty {
                        Text(model.feedback)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !model.drafts.isEmpty {
                        Text("SAVE FOR LATER RETRIEVAL")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        DraftCardsEditor(drafts: $model.drafts)
                    }
                }
            }
            HStack {
                Spacer()
                if model.drafts.isEmpty {
                    Button("Done") { model.onClose?() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .controlSize(.small)
                } else {
                    Button("No cards") { model.onClose?() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                    let n = model.drafts.filter(\.include).count
                    Button(n == 1 ? "Add card" : "Add \(n) cards") { model.addDrafts() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(recallPurple)
                        .disabled(n == 0)
                }
            }
        }
    }

    private var manualStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved. Turn it into a card you'll retrieve in 1, 3, 7… days?")
                .font(.system(size: 12))
            TextField("Question to answer from memory later", text: $model.manualPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2...3)
            TextField("Reference answer", text: $model.manualAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("No card") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                Button("Add card") { model.addManual() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(recallPurple)
                    .disabled(model.manualPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func errorStage(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your recall is saved. Claude couldn't check it:")
                .font(.system(size: 12))
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack { Spacer(); Button("Close") { model.onClose?() }.controlSize(.small) }
        }
    }
}

/// Editable list of proposed cards with include toggles.
struct DraftCardsEditor: View {
    @Binding var drafts: [RecallCardDraft]

    var body: some View {
        VStack(spacing: 8) {
            ForEach($drafts) { $d in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $d.include)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: d.kind.icon).font(.system(size: 9))
                            Text(d.kind.displayName.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.8)
                            if !d.topic.isEmpty {
                                Text("· \(d.topic)").font(.system(size: 9)).lineLimit(1)
                            }
                        }
                        .foregroundStyle(recallPurple)
                        TextField("Prompt", text: $d.prompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1...4)
                        TextField("Answer", text: $d.answer, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1...8)
                    }
                    .opacity(d.include ? 1 : 0.45)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}
