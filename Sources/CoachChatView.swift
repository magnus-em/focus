import AppKit
import FocusCore
import SwiftUI

/// "Ask the coach" window: `focus://coach`, the ⌃⌥⌘J switcher, or
/// "Talk it through" after the morning recall.
@MainActor
final class CoachChatWindow: NSObject, NSWindowDelegate {
    static let shared = CoachChatWindow()
    private var window: NSWindow?

    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: CoachChatView()))
        w.title = "Coach"
        w.setContentSize(NSSize(width: 520, height: 640))
        w.minSize = NSSize(width: 420, height: 460)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

struct CoachChatView: View {
    @State private var turns: [CoachChat.Turn] = []
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @AppStorage(Coach.enabledKey) private var coachEnabled = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if turns.isEmpty { intro }
                        ForEach(Array(turns.enumerated()), id: \.offset) { i, t in
                            bubble(t).id(i)
                        }
                        if busy {
                            ProgressView().controlSize(.small).id(-1)
                        }
                        if let error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) { proxy.scrollTo(turns.count - 1, anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your days, or say \u{201C}quiz me\u{201D}", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send() }
                Button("Send") { send() }
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 460)
        .onAppear { focused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about your days")
                .font(.system(size: 15, weight: .semibold))
            Text("Answers come from the nightly day records and today's screen log, with the day and time they come from.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !coachEnabled {
                Text(Coach.consent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on the cloud coach") { coachEnabled = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ForEach(CoachChat.suggestions, id: \.self) { s in
                Button(s) { send(s) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func bubble(_ t: CoachChat.Turn) -> some View {
        HStack {
            if t.fromUser { Spacer(minLength: 60) }
            Text(t.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(t.fromUser ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
            if !t.fromUser { Spacer(minLength: 60) }
        }
    }

    private func send(_ text: String? = nil) {
        let q = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard let client = Coach.client else {
            error = coachEnabled ? "No xAI key in the Keychain (service \(XAIKey.service))."
                : "Turn on the cloud coach first (above, or Settings → Coach)."
            return
        }
        let history = turns
        input = ""
        error = nil
        busy = true
        turns.append(.init(fromUser: true, text: q))
        Task { @MainActor in
            defer { busy = false }
            let worker = CoachDayWorker.shared
            let prompt = CoachChat.prompt(records: worker.recentRecords(days: 7), today: await worker.todayEvidence(),
                                          history: history, question: q)
            let model = XAIClient.Model.strong
            let estimate = XAIClient.estimateUSD(model: model, text: CoachChat.system + prompt, images: 0,
                                                 maxOutputTokens: 4000, reasoningEffort: "low")
            do {
                let reply = try await Coach.budget.run(estimateUSD: estimate, model: model, purpose: "chat") {
                    try await client.complete(model: model, system: CoachChat.system, text: prompt,
                                              schema: CoachChat.schema, reasoningEffort: "low",
                                              maxOutputTokens: 4000, timeout: 300)
                }
                let answer = ((try? JSONSerialization.jsonObject(with: reply.json)) as? [String: Any])?["answer"] as? String
                turns.append(.init(fromUser: false, text: answer ?? "(no answer)"))
            } catch {
                self.error = CoachDayWorker.describe(error)
            }
        }
    }
}
