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
                Label(name, systemImage: icon(for: name))
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

private func icon(for category: String) -> String {
    switch category.lowercased() {
    case "sleep": return "bed.double.fill"
    case "meals": return "fork.knife"
    case "exercise": return "figure.run"
    case "class": return "graduationcap.fill"
    case "commute": return "tram.fill"
    case "social": return "person.2.fill"
    case "leisure": return "gamecontroller.fill"
    case "chores": return "basket.fill"
    case "admin": return "tray.full.fill"
    case "swe": return "chevron.left.forwardslash.chevron.right"
    case "quant": return "function"
    case "ai": return "sparkles"
    case "hw": return "pencil.and.list.clipboard"
    default: return "scope"
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
            let color = s.isBreak ? Color(red: 0.27, green: 0.62, blue: 0.83) : categoryColor(s.label)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.label, systemImage: s.isBreak ? "cup.and.saucer.fill" : icon(for: s.label))
                        .font(.headline)
                        .foregroundStyle(color)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionRow(isBreak: s.isBreak)
                }
            } compactLeading: {
                Image(systemName: s.isBreak ? "cup.and.saucer.fill" : icon(for: s.label))
                    .foregroundStyle(color)
            } compactTrailing: {
                Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: s.isBreak ? "cup.and.saucer.fill" : icon(for: s.label))
                    .foregroundStyle(color)
            }
        }
    }
}

private struct LockScreenCard: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        let color = state.isBreak ? Color(red: 0.27, green: 0.62, blue: 0.83) : categoryColor(state.label)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(state.label).font(.title3.weight(.semibold))
                if !state.isFocus && !state.isBreak {
                    Text("life").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
            }
            Text("since \(state.since.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ActionRow(isBreak: state.isBreak)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Break / Stop right on the card; switching categories is the control's job.
private struct ActionRow: View {
    let isBreak: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !isBreak {
                Button(intent: TakeBreakIntent(minutes: 0)) {
                    Label("Break", systemImage: "cup.and.saucer.fill").frame(maxWidth: .infinity)
                }
                .tint(Color(red: 0.27, green: 0.62, blue: 0.83))
            }
            Button(intent: StopFocusIntent()) {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.gray)
        }
        .buttonStyle(.borderedProminent)
        .font(.subheadline.weight(.medium))
    }
}
