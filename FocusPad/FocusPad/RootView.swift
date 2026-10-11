import SwiftUI
import FocusCore

enum PadTab: String, Identifiable, CaseIterable, Hashable {
    case timer, overview, daylog, problems, homework, scratch
    case stats, insights, awards, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .timer:    return "Timer"
        case .overview: return "Overview"
        case .daylog:   return "Day Log"
        case .problems: return "Problems"
        case .homework: return "Homework"
        case .scratch:  return "Scratchpad"
        case .stats:    return "Stats"
        case .insights: return "Insights"
        case .awards:   return "Awards"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .timer:    return "timer"
        case .overview: return "rectangle.3.group"
        case .daylog:   return "calendar.day.timeline.left"
        case .problems: return "checkmark.circle"
        case .homework: return "book"
        case .scratch:  return "list.bullet.rectangle"
        case .stats:    return "chart.bar.xaxis"
        case .insights: return "sparkles"
        case .awards:   return "rosette"
        case .settings: return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .timer:    return FocusColors.focusRed
        case .overview: return FocusColors.focusRed
        case .daylog:   return .indigo
        case .problems: return .blue
        case .homework: return .green
        case .scratch:  return .yellow
        case .stats:    return .purple
        case .insights: return .mint
        case .awards:   return .yellow
        case .settings: return .gray
        }
    }
}

/// Sidebar uses a Button-driven selection rather than `List(selection:)` tags
/// because the tagged approach was failing to update the detail view on real
/// hardware. Buttons set @State directly — bulletproof — and the detail closure
/// reads that state, with `.id()` forcing a fresh NavigationStack per tab.
struct RootView: View {
    @State private var selection: PadTab = .timer
    /// On iPhone the split view collapses to a stack; this is which side shows.
    @State private var compactColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            sidebar
        } detail: {
            NavigationStack {
                destination(for: selection)
            }
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(FocusColors.focusRed)
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach([PadTab.timer, .overview, .daylog]) { tab in
                    sidebarButton(tab)
                }
            }
            Section("Capture") {
                ForEach([PadTab.problems, .homework, .scratch]) { tab in
                    sidebarButton(tab)
                }
            }
            Section("Analytics") {
                ForEach([PadTab.stats, .insights, .awards]) { tab in
                    sidebarButton(tab)
                }
            }
            Section {
                sidebarButton(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Focus")
    }

    private func sidebarButton(_ tab: PadTab) -> some View {
        Button {
            Haptics.tap()
            selection = tab
            compactColumn = .detail
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tab.tint)
                    .frame(width: 22)
                Text(tab.label)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == tab {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == tab ? tab.tint.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func destination(for tab: PadTab) -> some View {
        switch tab {
        case .timer:    TimerScreen()
        case .overview: DashboardScreen()
        case .daylog:   DayLogScreen()
        case .problems: ProblemsScreen()
        case .homework: HomeworkScreen()
        case .scratch:  ScratchpadScreen()
        case .stats:    StatsScreen()
        case .insights: InsightsScreen()
        case .awards:   AwardsScreen()
        case .settings: SettingsScreen()
        }
    }
}
