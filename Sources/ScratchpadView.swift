import SwiftUI
import FocusCore

struct ScratchpadView: View {
    @ObservedObject var store: ScratchStore
    @State private var newText = ""
    @FocusState private var inputFocused: Bool

    private let accent = Color(red: 0.96, green: 0.36, blue: 0.36)

    var body: some View {
        VStack(spacing: 0) {
            // Quick-add bar (always visible at top)
            HStack(spacing: 8) {
                TextField("Capture a thought...", text: $newText)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit { addItem() }

                if !newText.isEmpty {
                    Button(action: addItem) {
                        Image(systemName: "return")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .iconTarget()
                    }
                    .buttonStyle(.plainHit)
                    .padding(-11)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
            .animation(.easeInOut(duration: 0.15), value: newText.isEmpty)

            Divider()

            if store.items.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Distracted by something?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Dump it here and get back to work.\nReview during your break.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Item list

    private var itemList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.items) { item in
                        ScratchRow(item: item, store: store)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }

            Divider()

            // Footer actions
            HStack(spacing: 12) {
                let unchecked = store.items.filter { !$0.isChecked }.count

                Text("\(unchecked) remaining")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                if store.hasChecked {
                    Button("Clear done") {
                        withAnimation { store.clearChecked() }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plainHit)
                }

                if store.items.count > 0 {
                    Button("Clear all") {
                        withAnimation { store.clearAll() }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plainHit)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func addItem() {
        guard !newText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            store.add(newText)
        }
        newText = ""
    }
}

// MARK: - Single row

private struct ScratchRow: View {
    let item: ScratchItem
    @ObservedObject var store: ScratchStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    store.toggle(item)
                }
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isChecked
                        ? Color(red: 0.22, green: 0.72, blue: 0.45)
                        : Color.secondary.opacity(0.4))
                    .iconTarget(32, height: 28)
            }
            .buttonStyle(.plainHit)
            .padding(.horizontal, -8).padding(.vertical, -6)

            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(item.isChecked ? .tertiary : .primary)
                .strikethrough(item.isChecked, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)

            Button {
                withAnimation { store.delete(item) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.quaternary)
                    .iconTarget(28, height: 28)
            }
            .buttonStyle(.plainHit)
            .padding(.horizontal, -9).padding(.vertical, -9)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.isChecked ? Color.secondary.opacity(0.03) : Color.secondary.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.2), value: item.isChecked)
    }
}
