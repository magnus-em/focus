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
                Text("Quick notes and settings for this device.")
                    .font(.subheadline).foregroundStyle(Color.secondaryText)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            Section {
                NavigationLink { ScratchpadScreen() } label: {
                    Label { Text("Notes") } icon: { Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.secondaryText) }
                }
                NavigationLink { SettingsScreen() } label: {
                    Label { Text("Settings") } icon: { Image(systemName: "gearshape").foregroundStyle(Color.secondaryText) }
                }
            } footer: {
                Text("Stats, recall, problems and the full Day and Week pages are on your Mac.")
            }
        }
        .listStyle(.insetGrouped)
        .readableWidth()
        .navigationTitle("More")
    }
}
