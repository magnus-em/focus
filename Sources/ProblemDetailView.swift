import SwiftUI
import FocusCore

struct ProblemDetailView: View {
    @ObservedObject var store: ProblemStore
    let problem: ProblemEntry
    @Binding var isShowing: Bool

    // Editable local state — saved on close
    @State private var confidence: Confidence
    @State private var needsReview: Bool
    @State private var notes: String
    @State private var url: String
    @State private var solveMinutes: Int?
    @State private var showDeleteConfirm = false

    private static let solveOptions: [(String, Int?)] = [
        ("—", nil), ("< 5m", 3), ("5–15m", 10), ("15–30m", 22), ("30m+", 45)
    ]

    init(store: ProblemStore, problem: ProblemEntry, isShowing: Binding<Bool>) {
        self.store = store
        self.problem = problem
        self._isShowing = isShowing
        self._confidence   = State(initialValue: problem.confidence)
        self._needsReview  = State(initialValue: problem.needsReview)
        self._notes        = State(initialValue: problem.notes)
        self._url          = State(initialValue: problem.url)
        self._solveMinutes = State(initialValue: problem.solveMinutes)
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        saveAndClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Problems")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plainHit)

                    Spacer()

                    if showDeleteConfirm {
                        HStack(spacing: 8) {
                            Button("Cancel") {
                                showDeleteConfirm = false
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plainHit)

                            Button("Delete") {
                                store.delete(id: problem.id)
                                isShowing = false
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red)
                            .buttonStyle(.plainHit)
                        }
                    } else {
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .iconTarget()
                        }
                        .buttonStyle(.plainHit)
                        .padding(-11)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        // Title + meta
                        VStack(alignment: .leading, spacing: 6) {
                            Text(problem.title)
                                .font(.system(size: 16, weight: .bold))

                            HStack(spacing: 8) {
                                if !problem.source.isEmpty {
                                    MetaBadge(text: problem.source, color: .secondary)
                                }
                                MetaBadge(text: problem.domain.rawValue, color: problem.domain.color)
                                MetaBadge(text: problem.difficulty.rawValue, color: problem.difficulty.color)
                                Spacer()
                                Text(formatDate(problem.date))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }

                            if !problem.categories.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(problem.categories, id: \.self) { cat in
                                            Text(cat)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(problem.domain.color)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(problem.domain.color.opacity(0.1))
                                                .cornerRadius(5)
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        // Confidence
                        VStack(alignment: .leading, spacing: 7) {
                            DetailLabel("CONFIDENCE")
                            HStack(spacing: 6) {
                                ForEach(Confidence.allCases, id: \.self) { conf in
                                    let sel = confidence == conf
                                    Button(conf.rawValue) { confidence = conf }
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(sel ? conf.color.opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(sel ? conf.color : Color.secondary)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(sel ? conf.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
                                        )
                                        .buttonStyle(.plainHit)
                                }
                            }
                        }

                        Divider()

                        // Solve time
                        VStack(alignment: .leading, spacing: 7) {
                            DetailLabel("SOLVE TIME")
                            HStack(spacing: 5) {
                                ForEach(Self.solveOptions, id: \.0) { label, value in
                                    let sel = solveMinutes == value
                                    Button(label) { solveMinutes = value }
                                        .font(.system(size: 10, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.18) : Color.secondary.opacity(0.07))
                                        .foregroundStyle(sel ? Color(red: 0.27, green: 0.62, blue: 0.83) : Color.secondary)
                                        .cornerRadius(7)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .stroke(sel ? Color(red: 0.27, green: 0.62, blue: 0.83).opacity(0.4) : Color.clear, lineWidth: 1)
                                        )
                                        .buttonStyle(.plainHit)
                                }
                            }
                        }

                        Divider()

                        // Needs review toggle
                        Button { needsReview.toggle() } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Needs review")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(needsReview ? Color.orange : .primary)
                                    Text("Mark to redo without AI assistance")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: needsReview ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 18))
                                    .foregroundStyle(needsReview ? Color.orange : Color.secondary.opacity(0.4))
                            }
                            .padding(10)
                            .background(needsReview ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.05))
                            .cornerRadius(9)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(needsReview ? Color.orange.opacity(0.3) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plainHit)

                        Divider()

                        // URL
                        VStack(alignment: .leading, spacing: 7) {
                            DetailLabel("LINK")
                            HStack(spacing: 8) {
                                TextField("https://", text: $url)
                                    .font(.system(size: 11))
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.secondary.opacity(0.07))
                                    .cornerRadius(7)
                                if !url.isEmpty, let parsed = URL(string: url),
                                   url.hasPrefix("http://") || url.hasPrefix("https://") {
                                    Button {
                                        NSWorkspace.shared.open(parsed)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color(red: 0.27, green: 0.62, blue: 0.83))
                                            .iconTarget()
                                    }
                                    .buttonStyle(.plainHit)
                                    .padding(-10)
                                }
                            }
                        }

                        Divider()

                        // Notes
                        VStack(alignment: .leading, spacing: 7) {
                            DetailLabel("NOTES")
                            ZStack(alignment: .topLeading) {
                                if notes.isEmpty {
                                    Text("Key insight, approach, what tripped you up…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $notes)
                                    .font(.system(size: 12))
                                    .frame(minHeight: 72)
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .background(Color.secondary.opacity(0.07))
                            .cornerRadius(8)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func saveAndClose() {
        var updated = problem
        updated.confidence   = confidence
        updated.needsReview  = needsReview
        updated.notes        = notes
        updated.url          = url
        updated.solveMinutes = solveMinutes
        store.update(updated)
        isShowing = false
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mm a"
            return "Today \(f.string(from: date))"
        } else if cal.isDateInYesterday(date) {
            f.dateFormat = "h:mm a"
            return "Yesterday \(f.string(from: date))"
        }
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }
}

private struct DetailLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}

private struct MetaBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }
}
