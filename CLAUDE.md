# Focus — macOS Focus Timer

macOS menu bar focus timer with day tracking, problem logging, and a standalone dashboard. SwiftUI + Swift Package Manager. Deployment target: macOS 14+.

Built for a quant + SWE interview prep workflow: focus sessions tagged by category (Quant / SWE / AI), problems logged by domain with confidence/difficulty, daily commitment + voice oath, hours-based daily goal.

## Location

The repo lives at `~/Code/focus` (moved out of `~/Documents` and renamed from `focus_tracker` on 2026-10-11). Never put it back under `~/Documents` or `~/Desktop`: iCloud Desktop & Documents evicts files to the cloud, and git/SwiftPM hang on the placeholders. `build.sh` refuses to run from those folders.

## Build & install

```bash
./deploy.sh      # build → back up SwiftData store → quit → replace /Applications/Focus.app → relaunch
```

Tests: `cd FocusCore && swift test` (recall scheduler, timer display, duration text). The app targets have none.

`build.sh` alone builds to `.build/app.noindex/Focus.app` (the `.noindex` keeps Spotlight from listing a duplicate). `/Applications/Focus.app` is the only copy that should exist. `deploy.sh` also deletes stale `Focus.app` / `LockIn.app` / `FocusTimer.app` bundles left in the repo root by older builds.

> **Always use `./build.sh` / `./deploy.sh`, never bare `swift build`.** Bare `swift build` only rebuilds `.build/release/Focus`, not the app bundle.

## Architecture

### Stores (ObservableObject, JSON-persisted)

| File | Role |
|------|------|
| `Sources/SessionStore.swift` | Work + break sessions (SwiftData `StoredWorkSession`). Computes today/lifetime metrics, streaks, consistency, best week, by-tag splits, daily summaries, heatmap data. |
| `Sources/DayStore.swift` | Day boundaries (`DayRecord { calendarDay, dayStart, dayEnd }`). SwiftData `StoredDayRecord`. |
| `Sources/ProblemStore.swift` | Logged problems per domain. SwiftData `StoredProblem`. |
| `Sources/ScratchStore.swift` | Scratchpad checklist items. SwiftData `StoredScratchItem`. |
| `Sources/HealthStore.swift` | Health habit log. SwiftData `StoredHealthEvent { date, kind }`; `HealthTracker` (Fap, Adderall) groups `HealthKind` cases (add a case for a new habit or dose, no schema change); each kind has an `amount` (1, or mg). Weekly totals paired with focus hours, dose-day vs off-day focus, days since last, longest gap. |
| `Sources/CommitmentStore.swift` | AVFoundation voice oath recorder. Audio at `oaths/YYYY-MM-DD.m4a`. |
| `Sources/AppSettings.swift` | All settings, UserDefaults-backed. Bundle id `com.magnus.focus`. |
| `Sources/LeetCodeStore.swift` | LeetCode grind tracking derived from `ProblemStore` (every solve is a normal SWE `ProblemEntry`, matched to the catalog by URL slug, then title). Streaks, pace vs target/deadline, pattern coverage, difficulty mix vs 20/60/20 target, solve-time medians vs 15/25/40m, redo queue, milestones, Smart pick, stopwatch (persisted in UserDefaults), evening nudge notification. |
| `Sources/RecallStore.swift` | Retrieval practice. SwiftData `StoredKnowledgeItem` (card: course, prompt, reference answer, kind, interval, nextDue), `StoredRecallAttempt` (response written before reveal, score 0–3, `hinted`, real `delayDays`), `StoredRecallNote` (free recall: `session` after a focus block, `yesterday` each morning). Due queue (most overdue first, capped at `recallDailyCap`), retention-by-delay buckets, weekly focus-vs-retention rows, hardest cards. Scheduler is `FocusCore/Recall.swift` (`RecallScheduler`: 1→3→7→14→30→60…; fluent skips a rung, partial/hint drops one, forgot → 1d). |
| `Sources/PresenceMonitor.swift` | Is anyone at this Mac. Away = screen lock, display sleep, system sleep, or 10 min without keyboard/mouse (backdated to last input); back = fresh input on an unlocked lit screen. `AwaySpan`s ≥ 10 min, device-local in `Focus/presence.json` (60 days). On launch backfills display-off spans from `pmset -g log` (~1 week of history, ~7s in the background). |
| `Sources/ScreenWatcher.swift` | Screen-content tracking. Every 15s and on each app switch while present — and not while an off-screen category runs (`ScreenWatcher.offScreenCategories`: Sleep, Meals, Exercise, Commute, Chores) unless there was keyboard/mouse input in the last 30s — a lit screen says nothing then, but using the Mac means you're back and should get a switch prompt: frontmost window via ScreenCaptureKit (needs Screen Recording; private apps like Passwords/Messages/Mail skipped) → Apple Vision OCR → label from `screenMemory` (UserDefaults, window → category learned from the user's picks) else the on-device Apple Intelligence model (`FoundationModels`, macOS 26, dynamic schema constrained to the categories; hints tuned so problem sets aren't "Reading"). Title, summary, reason and uncertainty are kept in `Focus/screen.json`, 30 days; optional local JPEG review evidence is kept separately for up to seven days/256 MiB; shown as a thin lane on the Dashboard day timeline and as the Dashboard **Activity log** (`ScreenActivityView.swift`, top of the right column): spans grouped into activity blocks (`ScreenWatcher.activities`, <1 min blips smoothed; windows keep a label until the model disagrees 3× in a row). Each block gets study notes (title + 2–6 sentence bullets) from the on-device model, written from distinct page text held **in memory only** (4h, never saved) and updated every 90s for the live block, with a final pass when a block ends; plain-text output because a schema makes the 3B model list bare terms. Notes in `Focus/screen-notes.json`, each with the block's `start`/`end`; matched to blocks by overlap (exact-start keys broke whenever smoothing moved an edge, and the writer then re-noted old blocks forever, so no notes after noon on 10/13). The live block is noted first. Live "Now" panel, compact rows for <2 min blips, tracked-label ✓/⇄ and a day agreement %. `ScreenCoach`: when ≥ `screenSuggestMinutes` (2) of ≥ 80% one category differs from what's running, corner card (reuses `AwayPanel`) offers a switch backdated to the run start. Evidence rules (learned the hard way: "switched to Class, walked to class, reopened laptop → Math for 30 min?"): only *active* snapshots count (keyboard/mouse within 90s; no snapshots at all after 5 min idle), only snapshots after the current category was picked, a 60s gap breaks the run, and sleep/lid/lock/display-off clears evidence and dismisses the card. "Still X" teaches the window → X and snoozes 20 min, but never teaches a life category (the screen doesn't define Class/Social). While an iPad screen-notes block runs, idle Mac spans (`ScreenSpan.active == false`) are dropped from the log so time isn't double-counted. Only the existing trusted learned-label focus-to-focus auto-switch may act without a prompt, with Undo; uncertain labels never supply switch evidence. Accept/decline counts in `screenSuggest.accepted/declined`. The model is only offered categories the screen can show (`FocusCategories.notFromScreen` excludes Sleep/Meals/Exercise/Commute/Chores and Class/Social; with Class on offer it called a ChatGPT chat about C "Class"). **Prompt log** (`PromptLog`): every switch card (screen and calendar-class) with the snapshots and page text (≤12 pages, 1500 chars each) behind it, then a follow-up line with the answer (switched/kept/closed; no line = ignored), JSON lines in `Focus/prompt-log.jsonl`, 14 days, Settings → Screen → Show in Finder. The user hands it to Claude to tune the rules: read it, find the bad prompts, fix the cause. It's the one place page text hits disk. More tuning (10/13): browser tab strip/bookmarks cropped from OCR (top 120pt) and left sidebars read after the main column; generic window titles (ChatGPT/Claude windows are all titled with the app name) never get or give learned labels; the model is told the running category and keeps it unless the screen clearly shows other work (the 3B model called two's-complement C review "Math"); learned windows need 45s instead of 2 min; a window-title change triggers a snapshot. **Chat titles**: ChatGPT/Claude (`chatApps`) title every window with the app name, so the conversation title is read from the window's title bar (longest main-column OCR line with minY > 0.955) and used as the window title — learning, stickiness and log names then work per chat. **Browser URL**: the Chrome extension `POST /tab`s the focused tab's url + title (not incognito, in memory only, `BrowserBridge.activeTab`); when it matches the window title it's passed to the model next to the title. **Auto-switch** (`screenAutoSwitch`, default on): focus→focus runs whose every snapshot came from your own labels (`Run.trusted`) switch without asking, with a 45s card offering Undo (`TimerManager.relabelRunning`, which renames without splitting and teaches the window back). Model-only evidence and anything with a life category stay a card. **Your checks**: ✓/✗ on each activity-log block (`ScreenWatcher.setCheck`, `Focus/screen-checks.json`, 60 days); ✓ teaches the block's windows its label, ✗ asks what it was and teaches that; header shows "Your checks: right/total this week". **Ignored apps** (`screenIgnoredApps`, Settings → Screen → Edit, or "Ignore" in the inspector / off-task card): never sampled and filtered out of `spans(from:to:)`, so past data drops too. **Inspector**: Dashboard activity log → "What it sees right now" (window, label + where it came from, summary, the coach's reason for card/no card, full OCR text); `focus://screen-debug` writes the same plus recent samples and memory to `Focus/screen-debug.json` for Claude. |
| `FocusCore/ScreenLabeler.swift` / `DeviceActivity.swift` | Shared on-device labeling (`classify`, `studyNotes`, category hints) for the Mac watcher and the iPad broadcast. `DeviceActivityCloud`: raw CloudKit (zone `FocusDeviceActivity` in the private DB, record type `DeviceActivity`, upsert by id) carrying iPhone/iPad app opens/closes and screen-broadcast blocks (title + notes only) to the Mac, which polls zone changes every 30s (`ScreenWatcher.pollDevices`, token in UserDefaults `deviceActivityToken`, cache `Focus/devices.json`) and merges them into the activity log with a device icon. Separate from the SwiftData mirror because the broadcast extension can't share that store. |
| `FocusPad/FocusBroadcast/` | ReplayKit broadcast upload extension "Focus Screen Notes" (iPad; needs Apple Intelligence, so not the iPhone 14 Pro Max). Started from Settings → Activity Log on the Mac or Control Center. Every 15s: Vision OCR → `ScreenLabeler.classify` (category change needs 3 agreeing snapshots) → blocks with notes every 90s, sent via `DeviceActivityCloud`. Frames/text never leave the iPad. Info.plist keys must live in `project.yml` (xcodegen rewrites the plist). |
| `FocusPad/FocusPad/HealthImport.swift` | Apple Health → day log on iPhone/iPad (HealthKit read-only; entitlement + `NSHealthShareUsageDescription` in `project.yml`): sleep stages merged into nights (wakes < 45 min don't split, 3h+) become Sleep, workouts 10 min+ become Exercise, **only in untracked gaps** (never overwrites, so re-runs and the Mac's morning fill-in can't double). Runs when the app becomes active (at most every 10 min), last 3 days, clamped to the running session's start. Settings → Apple Health toggle (`healthImport`, default on). Installed and launched on both devices in this Codex session; Health authorization/import still needs functional verification. |
| `FocusPad/FocusPad/DeviceActivityIntents.swift` | `LogAppIntent` ("Log App", app + Opened/Closed) for Shortcuts personal automations → `DeviceActivity` open/close. Mac turns opens into spans until the next event on that device (max 30 min), category from `screenMemory` key `ios|<app>` else the Mac's model. |
| `Sources/BrowserStore.swift` | Chrome extension data. SwiftData `StoredBlockEvent` (domain, category at the time, `wasFocus`, reason, `bypassed`) and `StoredBrowsingSpan` (active-tab time per domain; same-domain spans < 90s apart merge; pruned after 120 days). |
| `Sources/LeetCodeCatalog.swift` | All ~3.6k LeetCode algorithm problems from `Sources/Resources/leetcode.json` (LeetCode GraphQL + NeetCode pattern labels + Blind75/NC150/NC250/Grind75/Grind169 bitmask). One primary pattern per problem (NeetCode label, else ordered tag rules). "Update from LeetCode" refetches into `Focus/leetcode-catalog.json`; newer `generated` wins. |

### Logic / glue

| File | Role |
|------|------|
| `Sources/LockInApp.swift` | App entry (`@main FocusApp`). MenuBarExtra. `PopoverContent` wires all stores, hosts tab switcher + commitment overlay. |
| `Sources/TimerManager.swift` | Timer state machine. `Phase { work, shortBreak, longBreak }` (no rawValue — `displayName` returns "Focus" / "Break"). Phase transitions, partial-session save, manual break, pause-grace auto-finalize, crash-recovery checkpoint, site-blocking orchestration. |
| `Sources/SiteBlocker.swift` | `/etc/hosts` + `pf` firewall blocking. Requires sudo helper at `/usr/local/bin/focustimer-blocker`. Cleanup on quit + next launch after crash. |
| `Sources/BrowserBridge.swift` | Loopback HTTP server (`NWListener`, 127.0.0.1:47821) for `ChromeExtension/`. `GET /state` (from `TimerManager.shouldBlockSites`, `bypassAllowed = !isFocusRunning`), `POST /events`. Refuses any request whose `Origin` isn't the extension (ID pinned by the manifest `key`). |
| `Sources/GlobalHotKey.swift` | Carbon global hotkey wrapper. Bindings live in `QuickSwitch`. |
| `Sources/QuickSwitch.swift` | Every no-popover way to change what's tracked. Hotkeys (⌃⌥⌘, all right-hand keys): Space pause/resume, K start/stop (`settings.quickStartTag`, default HW), J switcher panel, L break, ; Recall, 0 stop. Categories use `QuickSwitch.categoryKeys` in tag order (U I O P M , . / Y H N 7 8 9 6 - =), both as direct hotkeys and inside the switcher panel. URL scheme `focus://switch/<cat>`, `stop`, `break?minutes=N`, `toggle`, `switcher`, `recall`, `dashboard` (via `FocusAppDelegate`). Opens/reopens the day; `HotKeyToast` confirms. Toasts commands applied from other devices. |
| `Sources/RecallCoach.swift` | Optional Claude client (raw `URLSession`, `claude-opus-5-5`, structured JSON output, `fallbacks: "default"`). Key in Keychain service `com.magnus.focus.anthropic` (falls back to `ANTHROPIC_API_KEY`). `reviewNote` (feedback + ≤2 cards), `draftCards` (from pasted notes), `grade` (suggested score + what's missing), `hint` (progressive, never the answer). |
| `Sources/RecallPanel.swift` | Corner panel when a focus block ≥ `recallMinMinutes` ends (`TimerManager.onFocusSegmentSaved`, i.e. switch/stop/break — not pause auto-finalize or crash recovery). Non-activating: never steals keystrokes; click to type. Write → Claude feedback + card drafts, or manual card without a key. Untouched prompts vanish after 10 min. |
| `Sources/ClassCalendar.swift` | EventKit (needs Calendar permission + `personal-information.calendars` entitlement; Google/Yale calendars come through System Settings → Internet Accounts). A class = timed, busy event with a course code in the title, "Instructor"/"CRN" in the notes, or exam/midterm/quiz/lecture in the title (free/optional/reminder events and Rugby don't match). **Rule from the user: in class you're only ever in Class.** While Class runs or a calendar class is on, no screen suggestions; if a calendar class is on and Class isn't running, one "In class: …" card per event offers Class backdated to the class start. **Class exit** (10/14): when Class is still running after the calendar class it covered has ended (and no other class is on), one "Class ended at 2:20, what since?" card per event when you're next at the Mac: the class before Class, Leisure, Meals or Break, backdated to the event end; "End Class at 2:20"; "Still in Class" and closing change nothing (`ClassCalendar.endedClass(since:)`, `ScreenCoach.suggestClassExit`, asked keys in `screenClassExitAsked`). Mac only so far. Status in Settings → Screen. |
| `Sources/AwayPanel.swift` | `AwayCoach` + corner card. On return from away during a focus block (≥ `awayPromptMinutes`): Still X / pick a category (`TimerManager.carveOut`, X resumes) / End X at the start of the away stretch. Life/break blocks are only asked about if the away stretch is ≥ 90 min or overnight (never for Sleep, never for idle-only). Nothing running + day open: asks about the untracked part of the away stretch. Idle nudge: day open, nothing running, at the Mac 10+ min → chips start a category backdated to when you sat down (max every 20 min; "Not today"). Untouched cards change nothing and vanish after 15 min. While any card is up, ⌃⌥⌘↩ takes its first suggestion and ⌃⌥⌘⌫ dismisses it (as ✕), from any app; registered only while the card shows. After clicking the card, ↩/Esc do the same; no focus ring. |
| `Sources/MorningJournal.swift` | `Dictation` (on-device `SFSpeechRecognizer` live transcript; needs the `audio-input` entitlement under hardened runtime + mic/speech usage strings in `build.sh`'s Info.plist) and `JournalShortcut` (runs `/usr/bin/shortcuts run <name> --input-path` — Apple Journal has no API, so a user-made shortcut does "Create Entry" in their Learning journal). |
| Labels, 10/13 additions | Few-shot: before asking the model, up to 4 of your labeled windows whose titles are similar (`NLEmbedding` sentence vectors, cosine ≥ 0.55) go into the prompt as examples; a near-identical one (≥ 0.8, no conflicting match) is used directly without the model ("your earlier answer for a similar window"). If the model throws (background rate limit, guardrails), the window keeps its last label (`ScreenLabeler.lastError` in the debug dump). Private-app snapshots don't break a run. |
| `Sources/FocusModes.swift` | Sets the macOS Focus mode for the running category by running the user's shortcuts `Focus School` / `Focus Personal` / `Focus Sleep` / `Focus Off` (apps can't set Focus directly; Share across devices carries it to iPhone/iPad). Category → mode map in UserDefaults `focusModeMap` (defaults: focus categories + Class → School, Sleep → Sleep, Break → Off, other life (Admin, Leisure, Meals…) → Off so nothing filters notifications; the user decided 10/13 that life time shouldn't restrict notifications), toggle `focusModesOn`, device-local, Settings → Focus Modes. Runs only when the wanted mode changes (2s debounce), not at launch, not when stopped. |
| `Sources/DayReviewView.swift` (evening) | **End of Day** window (`EveningReviewWindowController`; End Day button, `focus://review`, tapping the commitment notification): focus vs goal by category, commitment kept/didn't, "what the screen saw you work on" (focus activity blocks grouped by name with their note bullets), off-task during focus, the rest of the day, and three fields (went well / got in the way / tomorrow start with) saved in `Focus/evening.json` (`EveningLog`, this Mac only). The morning recall shows last night's "start with". |
| Distractions (`ScreenActivityView.swift`) | `ScreenWatcher.drifts`: active screen spans labeled a life category (Leisure, Reading, Admin) during a focus session, merged across <30s gaps, ≥30s each. Dashboard card "Off-task during focus" under the activity log: count, minutes, per focus hour, by category and source, 7-day bars. Computed from spans, nothing stored. "Still X" on a focus→life card doesn't teach the window (it's a side trip, counted here). |
| `Sources/DesignGallery.swift` + `scripts/shots.sh` + `VirtualDisplay/` | Claude's eyes for UI work. `focus://gallery?view=popover-N[s|l]|dashboard|review&dark=0|1&virtual=1` opens that screen with live data in a plain window (`popover-0s`/`popover-0l` = Now page small/expanded; N = page: 1 Stats, 2 Problems, 3 Scratchpad, 4 Settings, 5 Health); `scripts/shots.sh [label] [views…]` screenshots each in light and dark into `.shots/<label>/` (gitignored). Windows go on a **virtual display** (`FocusVirtualDisplay`, an ObjC target over CoreGraphics' private `CGVirtualDisplay`, like DeskPad; 1600×1100 HiDPI, vendor id 0xF0C5, placed diagonally off the bottom-right corner of the real screens; released 30s after the last gallery window, or by `gallery-close?display=0` at the end of the script), opened with `open -g`, so it runs while the user works: verified 10/13 that no window moved and nothing showed. Glass renders there (it's a real display), unlike behind-the-desktop windows on the user's screen (white, missing text). The screen watcher skips the virtual display. `SHOTS_VIRTUAL=0` falls back to the user's screen, then only while idle ≥ 120s. Never pop windows over the user's work. |
| Dashboard, 10/13 additions | `ExamRadarSection` (calendar exams/midterms/finals in 30 days via `ClassCalendar.exams`, countdown, subject hours this week from the course code: MATH → Math, CPSC/CS → SWE) and `InsightsSection` (focus and drift by hour of day over 4 weeks, best 3-hour window with below-average drift; weekly letter via `RecallCoach.weeklyLetter`, cached per week in `weeklyLetter`). |
| Switcher (`QuickSwitch.swift`) | ⌃⌥⌘J is Spotlight-style since 10/13: type to filter categories and commands ("break 15", stop, dashboard, recall, end day), ↑↓, ↩, Esc. The direct ⌃⌥⌘ letter hotkeys still switch without it. |
| Scenes (`FocusModes.swift`) | Any shortcut named "Scene <category>" ("Scene Math", "Scene Break") runs when you switch to that category: Home/HomePod scenes, lights, music. Independent of the Focus mode toggle. |
| `scripts/agent` + `scripts/lock.sh` | Coordination between Claude Code and Codex (10/14): mailbox, atomic per-session file claims and one kernel-held install lock, state in `agent-bus-state/` (gitignored); hooks in `.codex/hooks.json` and `.claude/settings.json` (gitignored) inject mail and block edits to the other agent's claimed files. The user requires Claude and Codex to follow each other's Focus-project instructions exactly, without repeat approval; resolve unclear or blocked instructions with the sender. Direct user instructions take precedence. Rules in `AGENTS.md`. |
| `Sources/MorningCorrectionView.swift` / `FocusCore/MorningReview.swift` | Morning commitment's optional three-stretch review: yesterday's largest unresolved screen/tracked disagreements or unknown labels, split at tracked/check boundaries and clipped before the running timer. Saved screenshot gallery, arbitrary category correction, Mixed/Skip without learning, local 60-day receipts and last-action Undo. SessionStore's review undo contract refuses restoration after intervening edits. No review is required to submit or skip the commitment. Hidden gallery: `morning-correction`; its preview never writes user data. |
| `Sources/CompletionPanel.swift` | Simple 2.5s success toast (`show(label:)`) shown when a focus session completes. |
| `Sources/Models.swift` | `WorkSession`, `WorkSession.SessionType` (with `isBreak`), `DailySummary`, `DayRecord`, `ProblemEntry` + enums, `ScratchItem`. |

### Views

| File | Role |
|------|------|
| `Sources/TimerView.swift` | Quick Panel: Fitness-style goal ring beside category + timer, cached daily focus-category totals above two minutes including live work, one attention line, shared native-glass transport controls, labeled Details disclosure. Dashboard is always visible in the header. Now / Stats / Problems / Notes / Health / More stay at the bottom. Details contains day strip, screen context and recent log; no drag handle. `FocusTransportControls` is reused by dashboard `NowPlayingBar`; `.glass` / `.glassProminent`, `GlassEffectContainer`, stable `glassEffectID`, Reduce Motion. |
| `Sources/CommitmentView.swift` | Daily commitment overlay (written text + optional voice oath). Triggered by Start Day. |
| `Sources/StatsView.swift` | Popover stats tab. Today card, 7-day card, focus split, 18-week heatmap, lifetime row. |
| `Sources/ProblemsView.swift` / `ProblemDetailView.swift` | Problem logging + review queue. SWE log sheet searches/browses `FocusCore/Grind75Catalog.swift` (8-week schedule) and prefills title/URL/difficulty/categories; progress matched by LeetCode URL slug, then title. |
| `Sources/ScratchpadView.swift` | Quick checklist. |
| `Sources/HealthView.swift` | Popover Health tab (heart chip). One-tap log + undo, backdate popover, 12-week chart, per-week count vs focus hours with median-split insight, recent list with delete. |
| `Sources/SettingsView.swift` | All settings UI. |
| `Sources/BlockedSitesView.swift` | Domain list editor for site blocking. |
| `Sources/LeetCodeView.swift` | Standalone LeetCode window (`LeetCodeWindowController`), opened from the popover's LeetCode button. Left: searchable/filterable browser. Right: Grind tab (today ring, stopwatch, problem card + attempt history, Smart/Random pick, redo queue, pace) and Stats tab (28-day chart, pattern grid, mix, speed, quality, lists, milestones). |
| `Sources/RecallView.swift` | Standalone Recall window (`RecallWindowController`; launcher tile, ⌃⌥⌘;, `focus://recall`). Review (prompt → typed answer → hint/reveal → optional Claude check → grade 1–4), Cards (browser + editor + "Draft from notes"), Journal (recall notes + feedback), Progress (unaided %, 1wk+ retention, recall coverage, delay buckets chart, week table). |
| `Sources/WeekView.swift` | Dashboard "Where time went" card (`WeekLedger`): 7 × 24h strips with away spans underlined (click a row → day timeline), hours by category vs the week before + Untracked, coverage %, focus, sleep (nights = merged Sleep blocks ≥ 3h; circular-mean bedtime/wake, ±spread), first focus + time from waking, avg focus block, focus logged while away from the Mac. Week ends today unless an older day is selected. |
| `Sources/DashboardView.swift` | Standalone NSWindow. Left: today's log (focus + breaks + problems, newest-first, click focus/problem rows to edit). Right: stat cards, problem progress, 14-day chart, focus split, insights, weak areas, lifetime row. `DashboardWindowController.open(...)` opens/refocuses. |

## Data model

### `WorkSession`
- `id: UUID`, `startTime: Date`, `durationMinutes: Double`, `type: SessionType`, `var label: String?`
- `SessionType`: `.work | .shortBreak | .longBreak` — `var isBreak: Bool` returns `type != .work`. Old `.shortBreak`/`.longBreak` data still decodes; new code writes only `.shortBreak` for breaks.

### `DayRecord`
- `id: UUID`, `calendarDay: Date` (start of day), `var dayStart: Date?`, `var dayEnd: Date?`
- `DayStore.todayRecord`, `isDayStarted` (started but not ended), `isDayEnded`.

### `ProblemEntry`
- `domain: ProblemDomain` (Quant / SWE), `categories: [String]`, `var difficulty: ProblemDifficulty`, `var confidence: Confidence`, `var needsReview`, `var notes`, `var url`, etc. Spaced-repetition `reviewDueDate` derived from confidence + needsReview.

### Storage paths
- `~/Library/Application Support/default.store` — SwiftData (SQLite) store for sessions, day records, problems, scratch, practice/mastery, timer state. Mirrored to CloudKit. Count sessions: `sqlite3 -readonly ~/Library/Application\ Support/default.store 'select count(*) from ZSTOREDWORKSESSION'`
- `~/Library/Application Support/Focus/backups/default-YYYY-MM-DD.store` — daily single-file snapshots (`FocusCore/StoreBackup.swift`), 14 kept. Restore = quit app, copy over `default.store`, delete its `-wal`/`-shm`.
- The old `*.json` files were migrated in May 2026 and survive only as `*.pre-swiftdata.bak`. `zetamac.json` and `sync.log` in `~/Library/Application Support/Focus/` are still live.
- `~/Library/Application Support/Focus/oaths/YYYY-MM-DD.m4a`
- UserDefaults `com.magnus.focus` (settings, commitment timestamp, timer crash checkpoint)

## Key behaviours

### Timer
- **Phases**: focus → break → focus. No long-break cycle anymore (single break duration in settings, default 10m).
- **Nothing ends on its own.** When a countdown hits 0 the session rolls into overtime (`extendRunway`): chime + Keep Going / Take a Break panel, menu bar shows `+MM:SS`, tracking continues until a switch/stop. Breaks do the same. Only pause grace ends a session automatically.
- **Open-ended encoding**: life blocks and overtime add `FocusCategories.openEndedSeconds` (24h) to `totalTime`, so the shared state's `endTime` is always in the future (peers treat a past `endTime` as finished). Display derives from `(total, remaining)` via `FocusCategories.timeString/progress`; `countdown(total:)` = total mod 24h (0 = life block).
- **Category is sticky**: `currentLabel` survives completion, breaks, stop and pause-grace; it only changes when the user picks one.
- **Two modes**: focus categories run a countdown (presets 15/25/45/60) that rolls into overtime; life categories and Break just count up (open-ended, ring stays full, "since h:mm").
- **Break** is a chip in the Life row (and ⌃⌥⌘L): saves what's running, then counts up until a switch/stop. Stored as `.shortBreak`. A break with explicit minutes (URL `?minutes=N`, iPad sheet) still counts down, then keeps counting. `startBreak` commands with `minutes == 0` are open-ended on every device.
- **Stop**: saves the running segment if ≥ 1 min. No skip button; switching a category ends a break.
- **Pause grace**: pausing arms an auto-finalize that saves + ends the session after `pauseGraceMinutes` (default 10). Bathroom-break safe; longer absences auto-end.
- **Crash recovery**: timer state checkpointed every 30s during work; on next launch the partial session is recovered into the store.
- **In-session adjustment**: ±5 / ±10 min chips during active work.
- **Quick presets**: 15 / 25 / 45 / 60m chips when idle on work.

### Categories (focus vs life)
- `settings.tags` = all categories (order = ⌃⌥⌘ category keys U I O P M , . / …, same keys in the switcher panel). `settings.lifeTags` (synced key `lifeTags`) = the life subset: tracked but not counted toward the goal. Toggle Focus/Life in the Stats tab category card.
- `WorkSession.isFocus` / `StoredWorkSession.isFocus` = work type and not a life label. All goal/streak/stats code uses `isFocus`; day logs and timelines show everything. `minutesByTag(includeLife:)` for full-day splits.
- Life categories start open-ended (count up, no presets). Colors: `categoryColor(_:)` in `DashboardView.swift`.
- Dashboard day timeline spans 0–24h; untracked gaps ≥ 5 min are dashed and clickable to back-fill a category or Break.
- `SessionStore.paint(start:end:label:)` relabels a range: overlapping saved sessions are trimmed/split around it, then it's filled. `fill` only adds.
- Morning "Fill in yesterday" splits gaps at away-span edges (≥ 30 min), marks the away parts "Away from Mac", and ranks Sleep first for overnight ones, so Sleep starts when you actually left the Mac rather than at the last block.

### Switching & remote commands
- **Switch = split at a timestamp.** `TimerManager.switchTo(_:at:)` / `FocusTimerEngine.switchTo(_:at:)` save the running segment up to `at` (if ≥ 1 min; shorter focus is just relabeled) and start the new category already running from `at`. Category chips mid-session switch rather than relabel.
- **Phone/iPad Shortcuts** (`FocusPad/FocusPad/FocusIntents.swift`: Switch Focus, Stop Focus Timer, Take a Break, plus Siri phrases) never touch `StoredTimerState`. They append a `StoredTimerCommand` (`FocusCore/TimerCommand.swift`); each device's `TimerStateSync` poll hands new commands to its engine, which applies them at the command's `createdAt`. A command is skipped if shared state was pushed after it (already acted on). Commands > 12h old are ignored; rows pruned after 7 days.
- When a peer's state names a different session (startTime differs > 3s), the receiver saves its own segment first (`closeSegmentIfReplaced`); session dedup (±3s, same label) absorbs double saves. Exception (`SharedSessionMemory` + `knowledgeStale` in both engines): if this device slept/was suspended (>2 min without ticks) or restored from a checkpoint, and its session was the shared one, it does **not** save it — whoever replaced it knew it and saved it. Without this, an iPad asleep since morning logged a 2.5h phantom session on relaunch. `focus://unlog?id=<uuid>` deletes one saved session through the app (so the delete syncs).
- `./install_ios.sh` builds FocusPad and installs on every connected iPhone/iPad. FocusPad is universal (iPhone + iPad); on iPhone the split view opens on the Timer (`preferredCompactColumn`).
- **iOS widgets** (`FocusPad/FocusWidgets`, iOS 18 extension): Control Center/Lock Screen/Action Button controls (Switch Category — configurable, one per category; Take a Break; Stop) and a Live Activity (category, count-up since start, Break/Stop buttons; Dynamic Island). Intents live in `FocusPad/Shared/FocusIntents.swift`, compiled into both targets; they're `LiveActivityIntent`s so they always run in the app process (bodies are `#if FOCUS_APP`). The extension reads categories from app group `group.com.magnus.focus` (`SharedStore`), mirrored by the app. `FocusLiveActivity.follow(engine)` keeps the activity in step with the engine; Mac-side switches reach it when the phone app runs (foreground or a CloudKit push — `aps-environment` + `remote-notification` background mode are now set).

### Day tracking
- **Start Day** button at top of TimerView. Records `dayStart` and (if commitment enabled) shows the commitment overlay.
- **End Day** button replaces it once started. Records `dayEnd`.
- App relaunch mid-day: if day is already started and commitment not done today, the overlay shows automatically.

### Recall (retrieval practice)
- Three loops: write-from-memory after each focus block, spaced retrieval of cards, and "what did you learn yesterday" before the timeline when opening the day (cues = titles of yesterday's activity-log blocks; their bullets only appear after Reveal, next to what you recalled, so the cues don't give the answers away; mic button dictates; on Reveal the text also goes to Apple Journal via the `journalShortcut` setting, off by default (Journal's Create Entry can't pick a journal on macOS 26), device-local) (`YesterdayRecallView` in `DayReviewView.swift`; runs before the commitment overlay, and before "fill in yesterday"; "Skip today" stored in UserDefaults `yesterdayRecallSkippedDay`).
- Only unaided Got it / Fluent counts as recall success; any hint caps the attempt at Partial. The typed response is saved as-is; Claude's suggestion is stored separately (`aiScore`, `aiFeedback`) and the user picks the grade.
- No composite "memory score": metrics stay separate and are framed as retrieval of studied material.
- Settings → Recall: `recallAfterSession`, `recallMinMinutes` (20), `morningRecall`, `recallDailyCap` (12), Claude key. Device-local (not in `SyncedDefaults.syncedKeys`).
- Testing views with a throwaway container: pass `cloudKitDatabase: .none`. The default `.automatic` mirrors to the real iCloud container and the rows come back into `default.store`.

### Commitment
- ON by default. Written commitment (required) + optional voice oath (AVFoundation, requires mic permission).
- Tracked via `lastCommitmentDateEpoch` in UserDefaults. `needsCommitmentToday` checks if it's a different calendar day than the last commitment.
- Today's `DayRecord.commitmentText` (SwiftData/CloudKit) is the source of truth: iOS only asks if it's empty, and the Mac re-marks the synced date from it on launch and popover open. `SyncedDefaults.isReloading` stops `reloadFromDefaults` from pushing every key back to KVS — that write-back let a lagging device revert today's commitment date to yesterday's.

### Goal
- Daily goal is **hours** (not sessions). Settings shows "Daily Target ... 4 h". Stored under UserDefaults key `dailyGoalHours`.
- Goal progress shown as outer ring (TimerView), `Xh / Yh` bar (StatsView), and `N% of Yh goal` card (Dashboard).

### Stats
- **Consistency** (`consistencyScore(days:)`): % of last N days with any work session. Surfaced in StatsView 7-day card and Dashboard insights.
- **Best week** (`bestWeekMinutes`): max hours in any rolling 7-day window. In lifetime row + Dashboard insights.
- **Streak**: consecutive days with a work session. Today counts only if logged.
- **By-tag splits**: 7-day and lifetime breakdowns.

### Site blocking
Requires admin password on first setup. Sets up sudoers entry + helper script. Modifies `/etc/hosts` + `pf` firewall only while a focus category runs (and on breaks with "Block during breaks too"); life categories (Leisure, Admin, Meals…) never block (user, 10/14: "why is this blocked im on leisure mode"). Cleanup runs on quit and on next launch after a crash via `SiteBlocker.cleanupIfNeeded()`.

### Chrome extension (`ChromeExtension/`)
- Load unpacked from `~/Code/focus/ChromeExtension`; ID `dljnfclilnaccokglnomfjlbbanapflo` is pinned by `key` in the manifest. After editing it, hit reload on chrome://extensions (deploy.sh doesn't touch it).
- Blocks the same domains at the same times as the hosts blocker (Settings → Site blocking), via a `declarativeNetRequest` redirect to `blocked.html`. Each load of the block page is one attempt; tabs swept when blocking starts aren't counted.
- No unlocking while a focus category runs. During breaks with blocking on: 30s wait + typed reason → 5 min unlock, logged as `bypassed`.
- Events queue in `chrome.storage.local` while the app is down. Last known state is kept for 3 min of unreachability, then blocking stops.
- Dashboard → Browser card: blocked count, during focus, per focus hour, bypassed, by category/site, time by site, sites during focus.

### LeetCode tracker
- Daily goal = `settings.sweGoal` (falls back to 3). Target/deadline: `leetCodeTarget`, `leetCodeDeadline` (falls back to `interviewDate`).
- Solve confidence drives the existing spaced repetition (`ProblemEntry.reviewDueDate`); "needed hints/AI" → `needsReview`. Redo queue uses each problem's latest attempt.
- `CommitmentReminder` is the app's only `UNUserNotificationCenterDelegate`; non-commitment taps go to `onOtherTap(identifier)` (LeetCode nudge opens the LeetCode window).
- Regenerating `leetcode.json`: page LeetCode GraphQL `questionList` 100 at a time (limit is capped at 100), keep `categoryTitle == "Algorithms"`.

### Menu bar
- Idle: `scope` SF Symbol.
- Active: countdown `MM:SS`, prefixed with `⏸` when paused.

## UI work

Read `DESIGN.md` first: principles, type/spacing/corner scale, color roles and the known problems. Loop: change one surface → `scripts/shots.sh <label>` (only while the user is away) → a separate reviewer (fresh agent) scores the shots against DESIGN.md out of 100 with numbered problems → fix → repeat until 85+ or three rounds; keep before/after shots. The user wants minimal involvement: they pick between directions once, then see a before/after sheet.

## Conventions

- **No comments in code unless WHY is non-obvious.** The user reads the diff; obvious comments are noise.
- **No "what changed" recap summaries** at end of responses — keep responses tight.
- **Edit existing files over creating new ones.**
- Install with `./deploy.sh` (never bare `swift build`).

## Roadmap status

### Done
- [x] Hours-based daily goal (was sessions)
- [x] Day boundaries (Start/End Day)
- [x] Single break duration + auto-break toggle
- [x] Manual breaks with presets, tracked as sessions
- [x] Daily written commitment + voice oath
- [x] Standalone dashboard window with editable log
- [x] Newest-first log ordering
- [x] Consistency score + best-week metric
- [x] Crash-recovery for partial sessions
- [x] Pause auto-finalize (bathroom-break safe)
- [x] In-session duration adjustment
- [x] Spaced-repetition review queue for problems
- [x] 18-week heatmap
- [x] In-progress focus session in dashboard log
- [x] Material-based glass pass (`GlassEffects.swift`)
- [x] CloudKit mirror health (`FocusCore/CloudSyncMonitor.swift`) in Settings + popover warning when failing/stale. Stale = no successful setup/import/export in 3 days (imports alone only fire when another device writes).
- [x] Daily store backups

- [x] Native Liquid Glass on macOS 26 (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)` on timer controls, tinted glass on selected chips); material fallback on 14–15
- [x] Grind 75 picker in Log Problem
- [x] Health tab (habit log, first habit: fap)
- [x] Recall: post-session free recall, spaced retrieval cards, morning yesterday reconstruction, optional Claude coach

### In flight (see HANDOFF.md)
- **Screen test mode is ON** (`screenEverySwitch`, Settings → Screen → "Ask on every switch it sees"): the user is switching SWE↔Math every ~5 min to test detection (cards after ~25s, window labels flip after 2 disagreements, "Still X" snoozes 2 min). Turn it off when they're done testing.
- Learning rules from that testing (10/13): accepting a card teaches only windows with ≥ 2 snapshots and ≥ 25% of the run; "Still X" in a chat app (`chatApps`) never teaches the chat; the running-category bias applies only to untitled windows ("Plan MATH 244 midterm prep" was called SWE under it); course codes in titles name the subject; working on this app with Claude/ChatGPT counts as Admin (AI is ML work). Time in Focus itself is logged ("Checking Focus", running category, never evidence for a switch). Tuning 10/14: while an off-screen category runs (Sleep, Meals…) only focus work gets a card (browsing in bed after starting Sleep drew four life-category cards, none taken); social feed titles (Threads, Instagram, TikTok, Facebook, X) are Leisure whatever the model says (`ScreenClassificationPolicy.isSocialFeed`; it called Threads Admin); class-card prompted/declined sets persist for a day so a relaunch mid-class doesn't ask twice.
- **Popover redesign**: built (A + B, native-Apple style; see DESIGN.md → Direction). Not re-reviewed since the tab bar, the Settings restyle and the End of Day story mode.
- **iOS install complete**: Focus installed and launched on iPhone and iPad in this Codex session. Health import and Siri need functional verification.
- Pending chores: user to reload the Chrome extension (new `/tab` posting); untested: iPad broadcast, calendar permission, dual monitors.
- A Claude scheduled task (`focus-prompt-log-tuning`, daily 8:30) reads `prompt-log.jsonl` and the debug dump and tunes the screen rules; it commits to main too.

### Ranked roadmap (2026-10-14, Claude + Codex, from an accounting of what's built, what's been asked for and actual usage; drafts in `agent-bus-state/planning/`)
Usage finding behind it: features that run on their own or ride a habit get used (tracking ~24 h/day since 10/10, blocking, the morning commitment 18 of 23 days); features that need a separate visit don't (End of Day 0, Recall 0 cards, 7 problems ever, 1 ✓/✗ check). New loops go into the morning commitment, the popover or one notification. No Apple Watch app for now (user, 10/14).

**Tier 1: make the log true**
1. **Time integrity across devices.** Reproduce 10/14's case first (Mac Class from 12:17, iPad Class from 12:42, `skipStaleSegment` at 19:08Z, both rows closed at 15:10; 10/13 logged 25.3 h), decide interval ownership, then fix with idempotent reconciliation. Surface save failures (SessionStore's `try? context.save()`), extend the existing CloudKit warnings, warn on low disk (heuristic). Daily diagnostic: clipped intervals vs the local day's real length (DST), overlaps; offers a fix, never repairs silently. Include iPhone/iPad in the tests.
2. **Class exit.** Remember the calendar event that started Class; at its end a quiet choice (still in class / resume X / end Class at the event end). Dismissing changes nothing.
3. **Junk-title guard.** Stop learning labels from non-titles (log lines, timestamps, code); offer a review of suspicious existing learned labels instead of purging.
4. **Verify Health import and Siri totals** end to end on devices; last-import status; fix the Siri total's missing midnight clipping.

**Tier 2: fixing and steering with little effort**
5. **Morning correction pass inside the morning commitment.** Yesterday's biggest disagreements and unknown stretches by minutes, with the saved screenshots; correct / Mixed / skip; reversible. Reuses the shipped evidence and corrections.
6. **Next block.** One concrete next action from exams, the commitment and last night's "start with"; the user picks the assignment/concept and an optional target (no guessed hour deficits; category hours are labelled as category hours); one evening notification proposing tomorrow's first block. Recall/problem queues join when they have content.
7. **Fix the log by saying it.** "I was in class 1–1:40, the rest was leisure" → preview → apply. Pilot as text in the popover; phone and Siri later.
8. **Optional course/task identity** under categories, one tap to attach or resume; needed before per-exam allocation.

**Tier 3: measure and make study count**
9. **Trust scorecard**: checked accuracy with sample size, agreement, cards accepted/kept/ignored, detection delay, Undo rate, test vs normal mode kept apart.
10. **Quiz from your own notes before an exam**, with the source block kept; good questions become cards.
11. **Possible drift shown next to focus**, not subtracted; only user-confirmed intervals ever come off.
12. **Optional simpler view** that hides dormant tabs only if the user turns it on.

**Later:** phone use during focus (Screen Time); iPad Notability verification, if the user studies on the iPad; Sunday weekly letter.
**Deferred:** Watch app, all-day voice capture, Places, HomePod extras, embedding classifier (until there are a few hundred checks), another redesign. Lecture transcription needs a consent decision first.

#### Screen Review spec (roadmap #2)
Goal: see in 30 seconds whether the auto-log was right today, fix what wasn't, and watch accuracy improve.
- **Scorecard** (top, four numbers with 14-day sparklines): agreement with what you tracked; your ✓/✗ accuracy; cards that were right (switched) vs false alarms (kept/closed); detection delay (how long after you actually changed activity the screen noticed). Plus auto-switch undo rate.
- **Review card** (built 10/13, `ScreenReviewSection`, under Snapshots): Triage (each ≥1 min stretch where screen ≠ tracked; Y = screen was right → `SessionStore.paint` + ✓ check that teaches the windows, N = you were right → ✗ check teaching your label, S = skip; disabled over the running session), Confusions (screen × tracked minutes, 7 days), Worst windows (Always X → `learn`, Ignore app), Cards (prompt-log ledger with answers). Spans now store `source` (you / model / held / focus). Snapshots shows a 14-day agreement sparkline.
- **Day ring** (built 10/13, `DayRingSection` in `DashboardView.swift`, top of the right column): 24h dial, tracked outside, screen inside, hover to scrub; beside it focus as the hero number with goal and "vs your usual <weekday> by now", then the streak.
- **Snapshot timeline** (built 10/13, `ScreenTimelineSection` in `ScreenActivityView.swift`, under the ring; live status line "Watching · next snapshot in 9s" / the current stage from `ScreenWatcher.stage` — Capturing, Reading text, Labeling, Writing notes — with last snapshot + coach reason on hover; lanes merge same-category snapshots into labeled blocks, end at now and follow it; "Switches it saw" list with your lag): every saved span at its real length (15s grain) above the smoothed blocks and the tracked lane, zoom Day/4h/1h/15m (segmented or pinch), hour chunks in a lazy horizontal scroll, hover/click for app · title · summary · tracked label, orange underline on disagreement. The user asked for this granularity explicitly ("zoom in and see what it thinks I'm doing down to 2 min").
- **Two-lane day timeline**: AI lane above your tracked lane, same scale; disagreements hatched orange. Click one → side panel: snapshots, label source (your answer / model / held by stickiness), the page excerpt if the prompt log has it, the card and your answer, and fix buttons (right · it was X · always X for this window · ignore app).
- **Triage mode**: keyboard walk through the day's disagreements (Y right / N + pick / S skip), oldest first; optional 30-second version in the morning review for yesterday.
- **Confusion grid**: AI said × truth (from checks, else tracked), e.g. Math↔SWE, so tuning targets the real confusions.
- **Worst windows**: apps/titles most often wrong, with one-click fixes.
- **Card ledger**: every card and auto-switch with its answer (from `prompt-log.jsonl`).
- Data to add: persist label source and snapshot agreement on `ScreenSpan`; compute detection delay from tracked switch times vs AI run starts. The daily 8:30 tuning task reads the same numbers.

### Vision: track every minute of the day
Homework stays the focus, but the app should cover the whole day with near-zero-friction switching from every surface. Phase 1 (done): focus/life categories, keep-tracking at countdown end, focus-only goal, fillable day timeline. Phase 2 (done 2026-10-11): presence detection, away/idle prompts, Sleep from away spans in the morning review, weekly "where time went". Phase 2 follow-ups: Settings → Away & Gaps has no per-category "away is expected" list yet (life categories are assumed away-friendly); away spans aren't synced, so iPad doesn't see them. Phase 3: Control Center / Action Button controls + Live Activity built 2026-10-11 (needs Xcode signed in to install, see HANDOFF.md). Still to do: Home Screen widget, Apple Watch app, HomePod via Siri Personal Requests → existing App Intents.

### Future ideas (not started)
- **Screen tracking, next steps**: auto-switch between focus categories (with Undo toast) once suggestion acceptance (`screenSuggest.accepted/declined`) is high; focus→leisure drift should stay a prompt or be logged as distraction, never silently relabel. Let the morning review show "yesterday you worked on…" from screen summaries. User-editable private-app list.
- **Better screen labels (on-device ML), in order**: (1) few-shot from the user's own labels: for each new page, retrieve the 3–5 most similar ✓/✗-checked or learned snapshots (on-device `NLEmbedding` sentence vectors over title + first ~300 chars) and put them in the classify prompt as examples; (2) a small classifier on those embeddings (kNN or logistic regression over `screen-checks.json` + `screenMemory`) that answers for familiar pages and only falls back to the Foundation model for new ones. Both need checked blocks as training data, so encourage ✓/✗ first. Later options: an adapter for Apple's on-device model (Apple's adapter training toolkit; retrain per OS model update) once there are a few hundred checks; opt-in Claude escalation only when a card is about to fire (page text leaves the Mac).
- **Brainstorm from 2026-10-13** (user's top picks first: 1 Health sleep/workouts, 2 Screen Time, 3 recall cards from notes, 4 HomePod scenes + voice, 5 lecture notes):
  - *Fill the day automatically*: HealthKit sleep and workouts → Sleep/Exercise blocks (iPhone app); CoreLocation visits (library, lecture hall, gym, dining hall) → suggested category backdated to arrival, learned from answers; walking/driving between places → Commute.
  - *Phone*: Screen Time API (FamilyControls/DeviceActivity) for phone use during focus into the off-task log; ManagedSettings shields during focus with the same 30s + reason bypass.
  - *Class*: on-device lecture transcription during calendar classes → Class block notes (consent + battery to check); verify iPad Notability handwriting reaches the log; exam countdown from calendar ("CPSC 3231 midterm") with hours studied for it.
  - *Recall*: block notes → Claude-drafted recall cards for approval; "tonight's 3 questions" in the evening review; "Hey Siri, quiz me" on HomePod/AirPods (spoken answer, Claude grades).
  - *HomePod/home*: Siri phrases via existing intents ("I'm starting math", "take a break") plus a spoken "how much have I focused today?" intent (check what HomePod runs); per-category Home scenes via shortcuts like Focus modes (focus = bright cool + focus sound, break = warm, sleep = off); spoken nudges through HomePod; HomePod temperature/humidity vs drift rate (check Shortcuts can read it); Apple TV playing during focus → off-task or "on a break?" (check feasibility).
  - *Watch*: complication / Action button switching; wrist tap on drift; heart rate/HRV during focus vs leisure.
  - *Insights*: best hours (fewest drifts, longest blocks) → schedule hard work there; commitment pre-filled from free calendar slots, exams and LeetCode pace; Sunday Claude-written weekly letter as a shareable page; add sleep and drift to the health correlations.
  - *Bigger*: shared live status with a study partner; auto-pause when Mac, iPad and phone all show you left.
- **All-day voice capture → a model of the user**: record everything the user says through the day (on-device transcription), build it into a long-term understanding of them: what they're learning, thinking about, struggling with. Needs strong privacy design (on-device, opt-in, retention, pause), and ties into the morning review and recall.
- Apple Journal hand-off exists (`JournalShortcut`) but is off: on macOS 26 Journal's Create Entry can't target a specific journal. Revisit when it can (seen in the OS 27 betas).
- Multi-day visual timeline (horizontal blocks for past days)
- Pace-toward-interview indicator (problems remaining ÷ days left)
- Weekly goal in addition to daily
- Editable break sessions (set label like "Lunch", "Gym")
- Notification quick-action to extend +5 min
- Sound customization

## Codex local screen review update

- Local review screenshots: `Sources/ScreenEvidenceStore.swift`; existing allowed front-window capture supplies JPEGs, at most 1600 pixels, stored only on this Mac in `Focus/screen-evidence`. Seven-day retention, 256 MiB and 12,000-image caps; background serial IO and downsampled loading. Settings → Screen provides saving toggle and delete. Private/ignored apps and Focus itself are excluded. Older stretches have no image. No screenshot upload or paid API.
- Review evidence is available in triage, expanded activities and pinned timeline snapshots. Arbitrary categories can correct completed stretches; Mixed/Unsure mark reviewed without changing tracking or teaching. Active timer ranges cannot be repainted.
- `FocusCore/ScreenClassificationPolicy.swift` holds AI evidence rules and `LocalTaskContext`: up to eight recent tasks, twenty-minute expiration, bounded 1600-character JSON context, memory only. Apple Vision OCR + FoundationModels text classify on current macOS 26.5. Detailed labels include reason and uncertainty; uncertainty never supplies coach/auto-switch evidence. Context clears across privacy/away/reset boundaries.
- Lessons from logs and real synthetic model checks: assistant brand and model integration are not ML study; quoted AI category definitions and chat sidebars can contaminate classification. Chat sidebars are excluded from OCR classification, generic/new-chat titles are never learned, learned/cached/held AI labels require current ML evidence. The local model can confidently invent a subject for an empty chat, so empty assistant screens have a deterministic uncertainty guard. All Focus-project work is Admin by the user’s explicit rule, including code and model integration. These are conservative task checks, not proof of all-day accuracy.
- Dashboard separates Today (activity + optional editable tracked log), Review (evidence/timeline), and Trends (existing charts). Day data caches refresh on store/date changes, main dashboard live totals refresh every thirty seconds while floating timer stays realtime. Static category wash replaces the 30fps background; expensive chart sections are deferred.
- Tests: `cd FocusCore && swift test`; isolated evidence worker: `bash scripts/tests/evidence-store-check.sh`. Synthetic Apple-model fixtures: `scripts/tests/local-classifier-check.swift`, compiled with ScreenLabeler.swift and ScreenClassificationPolicy.swift; no user data or SwiftData stores.
- Screenshot QA: `SHOTS_WAIT=8 scripts/shots.sh <label> dashboard dashboard-review dashboard-trends`; all gallery surfaces stay on the hidden virtual display.

- User rule: all Focus-project work in Claude, ChatGPT or Codex is Admin, never homework/SWE/AI. This explicit rule overrides old learned labels and may automatically switch to Admin after sustained active evidence, with Undo; other life-category switches still require a prompt.
