import SwiftUI

struct LearnedLabelReviewView: View {
    @ObservedObject private var watcher = ScreenWatcher.shared
    var preview = false
    @State private var previewResolved: Set<String> = []
    @State private var error: String?

    private var entries: [ScreenWatcher.SuspiciousLabel] {
        if preview {
            return [ScreenWatcher.SuspiciousLabel(
                key: "com.anthropic.claudefordesktop|2026-10-13 22:27:24.175 xcodebuild[36709:200932",
                title: "2026-10-13 22:27:24.175 xcodebuild[36709:200932", category: "Math",
                reason: "Starts with a log timestamp"),
                ScreenWatcher.SuspiciousLabel(key: "com.example.editor|let category = math",
                    title: "let category = math", category: "SWE", reason: "Looks like a variable assignment")]
                .filter { !previewResolved.contains($0.key) }
        }
        return ScreenWatcher.suspiciousLabels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review learned labels").font(.system(size: 15, weight: .semibold))
            Text("These look like log output or code rather than window titles. They stay saved, but won't supply labels unless you keep them. New labels won't be learned from these titles.")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty {
                Label("No suspicious labels to review", systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.category).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(entry.reason).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(entry.title).font(.system(size: 12, design: .monospaced)).lineLimit(3)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button { resolve(entry, keep: true) } label: {
                            Text("Keep label").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .help("Explicitly keep using this saved title and category")
                        Button { resolve(entry, keep: false) } label: {
                            Text("Remove label").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .help("Forget only this learned label; your tracked time and checks stay unchanged")
                    }
                    .font(.system(size: 13)).buttonStyle(.bordered)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
        }
    }

    private func resolve(_ entry: ScreenWatcher.SuspiciousLabel, keep: Bool) {
        if preview {
            previewResolved.insert(entry.key)
        } else if !ScreenWatcher.reviewLearnedLabel(entry, keep: keep) {
            error = "That label changed while you were reviewing it. Please review its current category."
        } else {
            error = nil
        }
    }
}
