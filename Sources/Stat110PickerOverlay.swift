import SwiftUI
import FocusCore

/// Shared prefill payload — `HomeworkLogOverlay` and the iPad's
/// `AddHomeworkSheet` both accept one of these so the picker can hand off
/// the title, source, and catalog ID without coupling to either UI.
struct Stat110PickerPrefill: Equatable {
    var title: String
    var source: String
    var catalogID: String?
}

/// macOS popover-style overlay that shows the Stat 110 problem catalog,
/// dims problems already logged (via `catalogID` match), and emits the
/// chosen `Stat110Problem` via `onPick`.
struct Stat110PickerOverlay: View {
    let completedIDs: Set<String>
    @Binding var isShowing: Bool
    let onPick: (Stat110Problem) -> Void

    @State private var expandedSets: Set<Int> = [
        Stat110Catalog.all.last?.setNumber ?? 0
    ]
    @State private var expandedSP: Set<Int> = [
        Stat110Catalog.all.last?.setNumber ?? 0
    ]
    @State private var expandedHW: Set<Int> = [
        Stat110Catalog.all.last?.setNumber ?? 0
    ]

    private var purple: Color { Color(red: 0.62, green: 0.45, blue: 0.92) }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Stat110Catalog.all) { set in
                            setCard(set)
                        }
                        Text("More problem sets coming. Adding HW3+ is a one-file change to Stat110Catalog.swift.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical.fill").foregroundStyle(purple)
            Text("STAT 110 — PICK A PROBLEM")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.5).foregroundStyle(.secondary)
            Spacer()
            Button { isShowing = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(.tertiary)
                    .iconTarget()
            }.buttonStyle(.plainHit).padding(-10)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private func setCard(_ set: Stat110ProblemSet) -> some View {
        let done = set.problems.filter { completedIDs.contains($0.id) }.count
        let total = set.problems.count
        let isExpanded = expandedSets.contains(set.setNumber)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded { expandedSets.remove(set.setNumber) }
                    else { expandedSets.insert(set.setNumber) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(set.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(done == total ? .green : purple)
                    if let url = URL(string: set.pdfURL) {
                        Link(destination: url) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .help("Open PDF")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .buttonStyle(.plainHit)

            if isExpanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 0) {
                    if !set.strategicPractice.isEmpty {
                        subhead("STRATEGIC PRACTICE",
                                expanded: expandedSP.contains(set.setNumber)) {
                            if expandedSP.contains(set.setNumber) {
                                expandedSP.remove(set.setNumber)
                            } else {
                                expandedSP.insert(set.setNumber)
                            }
                        }
                        if expandedSP.contains(set.setNumber) {
                            ForEach(set.spByTopic, id: \.topic) { group in
                                Text(group.topic)
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(purple.opacity(0.85))
                                    .padding(.horizontal, 12)
                                    .padding(.top, 6)
                                ForEach(group.items) { p in problemRow(p) }
                            }
                        }
                    }
                    if !set.homework.isEmpty {
                        subhead("HOMEWORK",
                                expanded: expandedHW.contains(set.setNumber)) {
                            if expandedHW.contains(set.setNumber) {
                                expandedHW.remove(set.setNumber)
                            } else {
                                expandedHW.insert(set.setNumber)
                            }
                        }
                        if expandedHW.contains(set.setNumber) {
                            ForEach(set.homework) { p in problemRow(p) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func subhead(_ text: String, expanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.12)) { toggle() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
        .buttonStyle(.plainHit)
    }

    private func problemRow(_ p: Stat110Problem) -> some View {
        let isDone = completedIDs.contains(p.id)
        return Button {
            onPick(p)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(0.5))
                    .font(.system(size: 13))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("#\(p.number)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let topic = p.topic {
                            Text(topic)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(purple.opacity(0.15)))
                                .foregroundStyle(purple)
                        }
                    }
                    Text(p.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .opacity(isDone ? 0.55 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
