# Morning handoff — iPad app build-out

Built overnight. Four commits on `main` (top → bottom):

1. `020adcc` — Local notifications on timer events; quick-add problem button on Timer toolbar
2. `88ad895` — Search field on Problems + Homework lists; JSON export from Settings
3. `843e9a6` — Awards screen, Insights screen, Today's Priorities, haptics, personal-best banner, sync diagnostics in Settings
4. `e5eeef2` — Core feature parity (timer, dashboard, stats, problems, homework, scratchpad, settings, day-log, sidebar nav)

All four land on top of the day's earlier `780f72e` merge.

## What's new on the iPad

| Tab | What you get |
|---|---|
| **Timer** | Ring countdown, presets (15/25/45/60), tag chips, ±5/±10 nudges mid-session, Take-a-Break sheet, break-kind selectors, Day Start/End buttons, daily commitment, **Today's Priorities** at-a-glance list |
| **Overview** | Apple-Fitness-style 3-ring (Focus / Problems / 7-day Consistency), **personal-best banner** when you hit a record, momentum vs yesterday, current+best streak, 14-day bar chart, week-over-week, focus-by-tag stacked bar, interview countdown, recent activity feed |
| **Day Log** | Per-day timeline view with hourly grid + block visualization, navigable back through history |
| **Problems** | Goal cards (daily + weekly) per domain, review-queue navigation, filter by domain or "review only", full detail screen (edit difficulty/confidence/notes/source/url, mark reviewed, delete) |
| **Homework** | List + detail with all fields editable |
| **Scratchpad** | Quick capture, check, reorder (drag), swipe-delete, clear-checked / clear-all |
| **Stats** | 18-week heatmap, 30-day consistency, problem breakdown, lifetime card |
| **Insights** | Auto-detected patterns: best day of week, peak hour, week-over-week change, consistency dip warning, problem-mix balance, pacing toward interview, break habits |
| **Awards** | 15 milestones (sessions, hours, streaks, best-day-4h, best-day-8h, problem counts) with progress shown |
| **Settings** | Daily goal, session/break length, pause-grace, auto-start toggles, tag editor, problem goals (daily + weekly), problem sources, interview date, **iCloud sync status probe** (account state + container info), danger-zone reset |

Sidebar navigation (NavigationSplitView) groups the tabs as **Focus / Capture / Analytics / Settings** with color-tinted icons. Adapts to compact width for portrait or split-view multitasking.

## Architecture notes

- **`FocusTimerEngine` in FocusCore** is the new platform-agnostic timer brain. Lives in `FocusCore/Sources/FocusCore/TimerEngine.swift`. Uses `ModelContext` to insert `StoredWorkSession`s directly — no separate store layer. Survives force-quit via UserDefaults checkpoint (same pattern as Mac's `TimerManager`). Handles background → foreground reconciliation via `UIApplication.didBecomeActiveNotification`.
- **`PadSettings`** wraps UserDefaults for iPad-side preferences. Per-device, not synced — same as Mac's `AppSettings`.
- **`PadStats`** centralizes pure-function stat helpers (streak, consistency, by-tag, week-over-week, etc.) so Dashboard, Stats, and Insights all share one implementation.
- **`TodayPriorities`** stores the day's top 3-5 todos in UserDefaults, auto-resets on day change.

## Build verification done overnight

- ✅ FocusCore builds clean for macOS (Mac app unaffected).
- ✅ FocusCore builds clean for iOS simulator (`arm64-apple-ios-simulator`).
- ✅ FocusCore builds clean for iOS device (`arm64-apple-ios17.0`).
- ✅ All FocusPad sources type-check + codegen clean for both simulator AND device target.
- ✅ Mac `swift build -c release` succeeds.
- ❌ Could not run `xcodebuild` end-to-end because iOS 26.5 platform isn't installed in Xcode (only the SDK is). To install the app on your iPad in the morning: open `FocusPad.xcodeproj` in Xcode, plug iPad in, hit Run. Or use `xcrun devicectl` like before.

## CloudKit sync state (where we left off)

Diagnosed last night to a **network-layer issue, not a code issue**:

- All entitlements correct, provisioning profile good, iCloud account fine.
- cloudd is hitting `Operation timed out` on the very first `CKModifyRecordZonesOperation`.
- Failing URL: `https://gateway.icloud.com:443/ckdatabase/api/client/zone/sync`, `protocol=h3` (HTTP/3 over QUIC / UDP).
- TCP to the same host works fine; UDP/QUIC is being dropped or rate-limited by your network.
- Suspects in order of likelihood: managed wifi (Yale), NordVPN tunnel leftovers (utun*MTU 1380 persisted even after killing the helper), router QoS rules.

**The new Settings → Sync section** now has a "Refresh Sync Status" button that calls `CKContainer.accountStatus`. Use it to check that the iPad sees the right iCloud account, and read the diagnostic detail.

To actually unblock sync:
- **Test:** iPhone hotspot → cellular bypasses the QUIC-blocking network. If it works there, you've confirmed the network is at fault.
- **Long-term workaround:** stay off the offending wifi when you need fresh sync, or look at router settings (disable any "QUIC/UDP throttle" feature).

## To install on iPad in the morning

```bash
cd ~/Code/focus/FocusPad
xcodegen generate   # already done last night, but harmless
open FocusPad.xcodeproj
# In Xcode: select "Magnus's iPad" destination, hit Run.
```

## Also added

- **Local notifications**: when you start a focus or break session, a `UNTimeIntervalNotificationTrigger` is scheduled at the expected completion moment. Cancels on pause/stop/skip, reschedules on ±5/±10. So you hear the bell even with the iPad asleep / app backgrounded.
- **Search**: native `.searchable()` on both Problems and Homework. Title, source, notes, categories.
- **JSON export**: Settings → Data → "Export Snapshot (JSON)" produces a single timestamped file (`focus-export-yyyy-MM-dd-HHmm.json`) with every session, problem, homework, day record, scratch item. Handed to UIActivityViewController so you can AirDrop, email, or save to Files.
- **Quick-add problem**: `+circle` toolbar button on the Timer screen opens the full AddProblemSheet without leaving the timer flow.

## Things I considered and skipped (not blockers)

- **Live Activity / Lock-screen widget**: requires a separate WidgetKit extension target. Useful, but adding a target mid-flight has too many ways to break the build. Worth a separate session.
- **App Intents / Shortcuts**: "Hey Siri, start a 25-minute focus" — same target-config caveat.
- **Sound on completion**: the Mac uses `NSSound`; iOS would need AVFoundation. The local notification's `.default` sound covers most of the gap.
- **Mac → iPad immediate sync without an iCloud-friendly network**: can't be fixed in code.

## File map (for orientation)

```
FocusCore/Sources/FocusCore/
  TimerEngine.swift           ← new, platform-agnostic timer brain

FocusPad/FocusPad/
  FocusPadApp.swift           ← wires container + settings + engine
  RootView.swift              ← NavigationSplitView sidebar
  PadSettings.swift           ← UserDefaults-backed settings
  PadStats.swift              ← stat helpers
  PadTheme.swift              ← design tokens (cards, headers, metric tiles)
  Haptics.swift               ← UIImpactFeedbackGenerator wrappers
  TodayPriorities.swift       ← UserDefaults-backed top-3 tasks
  DataExport.swift            ← JSON snapshot + ShareSheet wrapper

  TimerScreen.swift           ← timer + day controls + priorities + quick-add
  DashboardScreen.swift       ← rings + personal best + momentum
  DayLogScreen.swift          ← per-day timeline
  StatsScreen.swift           ← heatmap + consistency + lifetime
  InsightsScreen.swift        ← auto pattern detection
  AwardsScreen.swift          ← Apple-Fitness-style milestones
  ProblemsScreen.swift        ← list + goal cards + filters
  ProblemDetailScreen.swift   ← detail + review queue
  HomeworkScreen.swift        ← list + detail
  ScratchpadScreen.swift      ← reorderable list
  SettingsScreen.swift        ← all settings + sync diagnostics

  Components/
    RingsView.swift           ← Fitness-style nested rings
    HeatmapView.swift         ← GitHub-style 18-week heatmap
```

Sleep well — everything compiles.
