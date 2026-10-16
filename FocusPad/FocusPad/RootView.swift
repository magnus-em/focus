import SwiftUI
import FocusCore

enum PadTab: String, Hashable {
    case now, today, adderall, more
}

/// Four tabs: what's running (and switching it), today's log, the dose
/// clock, and Notes and Settings. Everything else lives on the Mac.
struct RootView: View {
    @State private var tab: PadTab = {
        #if DEBUG && targetEnvironment(simulator)
        return PadTab(rawValue: UserDefaults.standard.string(forKey: "startTab") ?? "") ?? .now
        #else
        return .now
        #endif
    }()
    @EnvironmentObject private var engine: FocusTimerEngine

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { NowScreen(tab: $tab) }
                .tabItem { Label("Now", systemImage: "timer") }
                .tag(PadTab.now)
            NavigationStack { TodayScreen() }
                .tabItem { Label("Today", systemImage: "calendar.day.timeline.left") }
                .tag(PadTab.today)
            NavigationStack { AdderallScreen() }
                .tabItem { Label("Adderall", systemImage: "pills.fill") }
                .tag(PadTab.adderall)
            NavigationStack { MoreScreen() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(PadTab.more)
        }
        .tint(.primary)
        .onOpenURL { url in
            // focus://adderall from the dose widget; focus://today, focus://now.
            guard url.scheme == "focus", let target = PadTab(rawValue: url.host ?? "") else { return }
            tab = target
        }
    }
}

private struct MoreScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink { ScratchpadScreen() } label: { Label("Notes", systemImage: "list.bullet.rectangle") }
                NavigationLink { SettingsScreen() } label: { Label("Settings", systemImage: "gearshape") }
            } footer: {
                Text("Stats, recall, problems and the full Day and Week pages are on your Mac.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }
}
