import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import FocusCore

@main
struct FocusWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SwitchCategoryControl()
        BreakControl()
        StopControl()
        FocusLiveActivityWidget()
    }
}

// MARK: - Control Center / Lock Screen / Action Button controls

/// Picked when adding the control: which category this button switches to.
struct SwitchControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Category"
    @Parameter(title: "Category") var category: FocusCategory?
}

struct SwitchCategoryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.magnus.focus.switch", intent: SwitchControlConfiguration.self) { config in
            let name = config.category?.id ?? "HW"
            ControlWidgetButton(action: SwitchFocusIntent(category: FocusCategory(id: name))) {
                Label(name, systemImage: categoryIcon(name))
            }
            .tint(categoryColor(name))
        }
        .displayName("Switch Category")
        .description("Start tracking a category. Add one per category you switch to often.")
        .promptsForUserConfiguration()
    }
}

struct BreakControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.magnus.focus.break") {
            ControlWidgetButton(action: TakeBreakIntent(minutes: 0)) {
                Label("Break", systemImage: "cup.and.saucer.fill")
            }
            .tint(Color(red: 0.27, green: 0.62, blue: 0.83))
        }
        .displayName("Take a Break")
        .description("Save what's running and count up a break.")
    }
}

struct StopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.magnus.focus.stop") {
            ControlWidgetButton(action: StopFocusIntent()) {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .displayName("Stop Tracking")
        .description("Stop and save whatever is being tracked.")
    }
}

// MARK: - Live Activity

struct FocusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { ctx in
            LockScreenCard(state: ctx.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            let color = s.isBreak ? breakBlue : categoryColor(s.label)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.label, systemImage: s.isBreak ? "cup.and.saucer.fill" : categoryIcon(s.label))
                        .font(.headline)
                        .foregroundStyle(color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    QuickRow(state: s)
                }
            } compactLeading: {
                Image(systemName: s.isBreak ? "cup.and.saucer.fill" : categoryIcon(s.label))
                    .foregroundStyle(color)
            } compactTrailing: {
                Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: s.isBreak ? "cup.and.saucer.fill" : categoryIcon(s.label))
                    .foregroundStyle(color)
            }
        }
    }
}

private let breakBlue = Color(red: 0.27, green: 0.62, blue: 0.83)

private struct LockScreenCard: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        let color = state.isBreak ? breakBlue : categoryColor(state.label)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(state.label).font(.title3.weight(.semibold))
                Text("since \(state.since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            QuickRow(state: state)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Switch to a frequent category, take a break, or stop, in one row.
private struct QuickRow: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            ForEach(state.quick ?? [], id: \.self) { tag in
                Button(intent: SwitchFocusIntent(category: FocusCategory(id: tag))) {
                    VStack(spacing: 2) {
                        Image(systemName: categoryIcon(tag)).font(.system(size: 14, weight: .semibold))
                        Text(tag).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(categoryColor(tag).opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
            if !state.isBreak {
                iconButton("cup.and.saucer.fill", color: breakBlue, intent: TakeBreakIntent(minutes: 0))
            }
            iconButton("stop.fill", color: .gray, intent: StopFocusIntent())
        }
        .foregroundStyle(.white)
    }

    private func iconButton(_ symbol: String, color: Color, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}
