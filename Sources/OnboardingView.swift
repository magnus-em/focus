import SwiftUI
import AppKit

// MARK: - Window controller

class OnboardingWindowController: ObservableObject {
    private var window: NSWindow?

    func open(settings: AppSettings) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(settings: settings) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        let vc = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: vc)
        w.title = "Welcome to Focus"
        w.setContentSize(NSSize(width: 560, height: 520))
        w.minSize = NSSize(width: 480, height: 460)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    let onFinish: () -> Void

    @State private var step = 0
    @State private var newCategory = ""
    @State private var draftCategories: [String] = []
    @State private var draftGoal: Int = 4

    private let blue = Color(red: 0.27, green: 0.62, blue: 0.83)
    private let red  = Color(red: 0.96, green: 0.36, blue: 0.36)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch step {
                case 0: welcomePage
                case 1: categoriesPage
                default: goalPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            footer
        }
        .onAppear {
            draftCategories = settings.tags.isEmpty ? ["Quant", "SWE", "AI"] : settings.tags
            draftGoal = settings.dailyGoal > 0 ? settings.dailyGoal : 4
        }
        .onDisappear {
            if !settings.hasCompletedOnboarding {
                if settings.tags.isEmpty { settings.tags = draftCategories }
                if settings.dailyGoal <= 0 { settings.dailyGoal = draftGoal }
                settings.hasCompletedOnboarding = true
            }
        }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("Focus")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 18 : 7, height: 7)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                } label: {
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                if step >= 2 {
                    settings.tags = draftCategories
                    settings.dailyGoal = draftGoal
                    settings.hasCompletedOnboarding = true
                    onFinish()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                }
            } label: {
                Text(step >= 2 ? "Get Started" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(continueEnabled ? red : Color.secondary.opacity(0.3))
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!continueEnabled)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var continueEnabled: Bool {
        switch step {
        case 1: return !draftCategories.isEmpty
        default: return true
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Focus")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("A menu-bar focus timer built for deep work and interview prep.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                bullet("scope", color: red,
                       title: "Lives in your menu bar",
                       body: "Look for the scope icon at the top of your screen — Focus has no Dock icon.")
                bullet("timer", color: red,
                       title: "Run focus sessions",
                       body: "Tag each session by category. Take breaks tagged meal, workout, or chill.")
                bullet("checkmark.circle", color: blue,
                       title: "Log problems by domain",
                       body: "Track Quant + SWE problems with difficulty, confidence, and a review queue.")
                bullet("chart.bar.fill", color: blue,
                       title: "Open the Dashboard",
                       body: "See your day's timeline, weak areas, and goal progress in one window.")
            }
            .padding(.top, 4)
        }
    }

    private func bullet(_ icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var categoriesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Categories")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Tag every focus session by category. Add or remove these later in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("Add a category…", text: $newCategory)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    .onSubmit(addCategory)
                Button(action: addCategory) {
                    Text("Add")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(canAdd ? .white : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(canAdd ? blue : Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }

            if draftCategories.isEmpty {
                Text("No categories yet. Add some above or pick from suggestions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(draftCategories, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag)
                                .font(.system(size: 12, weight: .medium))
                            Button {
                                draftCategories.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(blue.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(blue.opacity(0.12))
                        .foregroundStyle(blue)
                        .cornerRadius(8)
                    }
                }
            }

            if !suggestionPool.isEmpty {
                Text("SUGGESTIONS")
                    .font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                FlowLayout(spacing: 6) {
                    ForEach(suggestionPool, id: \.self) { s in
                        Button {
                            if !draftCategories.contains(s) { draftCategories.append(s) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                                Text(s).font(.system(size: 12))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.07))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var goalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Daily Goal")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Pick a daily focus-hours target. You'll see live progress as you work — change anytime in Settings.")
                .font(.system(size: 13)).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach([2, 4, 6, 8], id: \.self) { h in
                    let sel = draftGoal == h
                    Button { draftGoal = h } label: {
                        VStack(spacing: 2) {
                            Text("\(h)").font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("hours").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(width: 72, height: 64)
                        .background(sel ? blue.opacity(0.18) : Color.secondary.opacity(0.07))
                        .foregroundStyle(sel ? blue : .primary)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(sel ? blue.opacity(0.5) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("YOU'RE ALL SET")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Text("After this, click the")
                    Image(nsImage: MenuBarRing.mark)
                    Text("icon at the top of your screen to open Focus.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var suggestionPool: [String] {
        ["Quant", "SWE", "AI", "Reading", "Writing", "Research", "Math", "Coursework", "Side Project"]
            .filter { !draftCategories.contains($0) }
    }

    private var canAdd: Bool {
        let t = newCategory.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !draftCategories.contains(t)
    }

    private func addCategory() {
        let t = newCategory.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !draftCategories.contains(t) else { return }
        draftCategories.append(t)
        newCategory = ""
    }
}

// MARK: - Flow layout for wrapping chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
