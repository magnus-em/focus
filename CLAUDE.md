# Focus — macOS Focus Timer

macOS menu bar focus timer with day tracking, problem logging, and a standalone dashboard. SwiftUI + Swift Package Manager. Deployment target: macOS 14+.

Built for a quant + SWE interview prep workflow: focus sessions tagged by category (Quant / SWE / AI), problems logged by domain with confidence/difficulty, daily commitment + voice oath, hours-based daily goal.

## Location

The repo lives at `~/Code/focus` (moved out of `~/Documents` and renamed from `focus_tracker` on 2026-10-11). Never put it back under `~/Documents` or `~/Desktop`: iCloud Desktop & Documents evicts files to the cloud, and git/SwiftPM hang on the placeholders. `build.sh` refuses to run from those folders.

## Build & install

```bash
./deploy.sh      # build → back up SwiftData store → quit → replace /Applications/Focus.app → relaunch
```

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
| `Sources/ScreenWatcher.swift` | Screen-content tracking. Every 15s and on each app switch while present — and not while an off-screen category runs (`ScreenWatcher.offScreenCategories`: Sleep, Meals, Exercise, Commute, Chores) unless there was keyboard/mouse input in the last 30s — a lit screen says nothing then, but using the Mac means you're back and should get a switch prompt: frontmost window via ScreenCaptureKit (needs Screen Recording; private apps like Passwords/Messages/Mail skipped) → Apple Vision OCR → label from `screenMemory` (UserDefaults, window → category learned from the user's picks) else the on-device Apple Intelligence model (`FoundationModels`, macOS 26, dynamic schema constrained to the categories; hints tuned so problem sets aren't "Reading"). Only title + one-line summary kept, `Focus/screen.json`, 30 days; shown as a thin lane on the Dashboard day timeline and as the Dashboard **Activity log** (`ScreenActivityView.swift`, top of the right column): spans grouped into activity blocks (`ScreenWatcher.activities`, <1 min blips smoothed; windows keep a label until the model disagrees 3× in a row). Each block gets study notes (title + 2–6 sentence bullets) from the on-device model, written from distinct page text held **in memory only** (4h, never saved) and updated every 90s for the live block, with a final pass when a block ends; plain-text output because a schema makes the 3B model list bare terms. Notes in `Focus/screen-notes.json`, each with the block's `start`/`end`; matched to blocks by overlap (exact-start keys broke whenever smoothing moved an edge, and the writer then re-noted old blocks forever, so no notes after noon on 10/13). The live block is noted first. Live "Now" panel, compact rows for <2 min blips, tracked-label ✓/⇄ and a day agreement %. `ScreenCoach`: when ≥ `screenSuggestMinutes` (2) of ≥ 80% one category differs from what's running, corner card (reuses `AwayPanel`) offers a switch backdated to the run start. Evidence rules (learned the hard way: "switched to Class, walked to class, reopened laptop → Math for 30 min?"): only *active* snapshots count (keyboard/mouse within 90s; no snapshots at all after 5 min idle), only snapshots after the current category was picked, a 60s gap breaks the run, and sleep/lid/lock/display-off clears evidence and dismisses the card. "Still X" teaches the window → X and snoozes 20 min, but never teaches a life category (the screen doesn't define Class/Social). While an iPad screen-notes block runs, idle Mac spans (`ScreenSpan.active == false`) are dropped from the log so time isn't double-counted. Never switches on its own. Accept/decline counts in `screenSuggest.accepted/declined`. The model is only offered categories the screen can show (`FocusCategories.notFromScreen` excludes Sleep/Meals/Exercise/Commute/Chores and Class/Social; with Class on offer it called a ChatGPT chat about C "Class"). **Prompt log** (`PromptLog`): every switch card (screen and calendar-class) with the snapshots and page text (≤12 pages, 1500 chars each) behind it, then a follow-up line with the answer (switched/kept/closed; no line = ignored), JSON lines in `Focus/prompt-log.jsonl`, 14 days, Settings → Screen → Show in Finder. The user hands it to Claude to tune the rules: read it, find the bad prompts, fix the cause. It's the one place page text hits disk. More tuning (10/13): browser tab strip/bookmarks cropped from OCR (top 120pt) and left sidebars read after the main column; generic window titles (ChatGPT/Claude windows are all titled with the app name) never get or give learned labels; the model is told the running category and keeps it unless the screen clearly shows other work (the 3B model called two's-complement C review "Math"); "Still X" over a Y card in an app means no more Y cards from that app for the rest of the block (`keptAgainst`); learned windows need 45s instead of 2 min; a window-title change triggers a snapshot. **Ignored apps** (`screenIgnoredApps`, Settings → Screen → Edit, or "Ignore" in the inspector / off-task card): never sampled and filtered out of `spans(from:to:)`, so past data drops too. **Inspector**: Dashboard activity log → "What it sees right now" (window, label + where it came from, summary, the coach's reason for card/no card, full OCR text); `focus://screen-debug` writes the same plus recent samples and memory to `Focus/screen-debug.json` for Claude. |
| `FocusCore/ScreenLabeler.swift` / `DeviceActivity.swift` | Shared on-device labeling (`classify`, `studyNotes`, category hints) for the Mac watcher and the iPad broadcast. `DeviceActivityCloud`: raw CloudKit (zone `FocusDeviceActivity` in the private DB, record type `DeviceActivity`, upsert by id) carrying iPhone/iPad app opens/closes and screen-broadcast blocks (title + notes only) to the Mac, which polls zone changes every 30s (`ScreenWatcher.pollDevices`, token in UserDefaults `deviceActivityToken`, cache `Focus/devices.json`) and merges them into the activity log with a device icon. Separate from the SwiftData mirror because the broadcast extension can't share that store. |
| `FocusPad/FocusBroadcast/` | ReplayKit broadcast upload extension "Focus Screen Notes" (iPad; needs Apple Intelligence, so not the iPhone 14 Pro Max). Started from Settings → Activity Log on the Mac or Control Center. Every 15s: Vision OCR → `ScreenLabeler.classify` (category change needs 3 agreeing snapshots) → blocks with notes every 90s, sent via `DeviceActivityCloud`. Frames/text never leave the iPad. Info.plist keys must live in `project.yml` (xcodegen rewrites the plist). |
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
| `Sources/ClassCalendar.swift` | EventKit (needs Calendar permission + `personal-information.calendars` entitlement; Google/Yale calendars come through System Settings → Internet Accounts). A class = timed, busy event with a course code in the title, "Instructor"/"CRN" in the notes, or exam/midterm/quiz/lecture in the title (free/optional/reminder events and Rugby don't match). **Rule from the user: in class you're only ever in Class.** While Class runs or a calendar class is on, no screen suggestions; if a calendar class is on and Class isn't running, one "In class: …" card per event offers Class backdated to the class start. Status in Settings → Screen. |
| `Sources/AwayPanel.swift` | `AwayCoach` + corner card. On return from away during a focus block (≥ `awayPromptMinutes`): Still X / pick a category (`TimerManager.carveOut`, X resumes) / End X at the start of the away stretch. Life/break blocks are only asked about if the away stretch is ≥ 90 min or overnight (never for Sleep, never for idle-only). Nothing running + day open: asks about the untracked part of the away stretch. Idle nudge: day open, nothing running, at the Mac 10+ min → chips start a category backdated to when you sat down (max every 20 min; "Not today"). Untouched cards change nothing and vanish after 15 min. |
| `Sources/MorningJournal.swift` | `Dictation` (on-device `SFSpeechRecognizer` live transcript; needs the `audio-input` entitlement under hardened runtime + mic/speech usage strings in `build.sh`'s Info.plist) and `JournalShortcut` (runs `/usr/bin/shortcuts run <name> --input-path` — Apple Journal has no API, so a user-made shortcut does "Create Entry" in their Learning journal). |
| `Sources/FocusModes.swift` | Sets the macOS Focus mode for the running category by running the user's shortcuts `Focus School` / `Focus Personal` / `Focus Sleep` / `Focus Off` (apps can't set Focus directly; Share across devices carries it to iPhone/iPad). Category → mode map in UserDefaults `focusModeMap` (defaults: focus categories + Class → School, Sleep → Sleep, Break → Off, other life → Personal), toggle `focusModesOn`, device-local, Settings → Focus Modes. Runs only when the wanted mode changes (2s debounce), not at launch, not when stopped. |
| `Sources/DayReviewView.swift` (evening) | **End of Day** window (`EveningReviewWindowController`; End Day button, `focus://review`, tapping the commitment notification): focus vs goal by category, commitment kept/didn't, "what the screen saw you work on" (focus activity blocks grouped by name with their note bullets), off-task during focus, the rest of the day, and three fields (went well / got in the way / tomorrow start with) saved in `Focus/evening.json` (`EveningLog`, this Mac only). The morning recall shows last night's "start with". |
| Distractions (`ScreenActivityView.swift`) | `ScreenWatcher.drifts`: active screen spans labeled a life category (Leisure, Reading, Admin) during a focus session, merged across <30s gaps, ≥30s each. Dashboard card "Off-task during focus" under the activity log: count, minutes, per focus hour, by category and source, 7-day bars. Computed from spans, nothing stored. "Still X" on a focus→life card doesn't teach the window (it's a side trip, counted here). |
| `Sources/CompletionPanel.swift` | Simple 2.5s success toast (`show(label:)`) shown when a focus session completes. |
| `Sources/Models.swift` | `WorkSession`, `WorkSession.SessionType` (with `isBreak`), `DailySummary`, `DayRecord`, `ProblemEntry` + enums, `ScratchItem`. |

### Views

| File | Role |
|------|------|
| `Sources/TimerView.swift` | Main timer UI. Day status row (Start/End Day), phase label, category chips, presets, ring (outer = goal progress in hours, inner = session progress), controls, ±5/±10 adjustment, Take a Break button + sheet, today's stats footer. |
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
Requires admin password on first setup. Sets up sudoers entry + helper script. Modifies `/etc/hosts` + `pf` firewall while a focus session is active. Cleanup runs on quit and on next launch after a crash via `SiteBlocker.cleanupIfNeeded()`.

### Chrome extension (`ChromeExtension/`)
- Load unpacked from `~/Code/focus/ChromeExtension`; ID `dljnfclilnaccokglnomfjlbbanapflo` is pinned by `key` in the manifest. After editing it, hit reload on chrome://extensions (deploy.sh doesn't touch it).
- Blocks the same domains at the same times as the hosts blocker (Settings → Site blocking), via a `declarativeNetRequest` redirect to `blocked.html`. Each load of the block page is one attempt; tabs swept when blocking starts aren't counted.
- No unlocking while a focus category runs. During breaks/life categories: 30s wait + typed reason → 5 min unlock, logged as `bypassed`.
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
_(none)_

### Vision: track every minute of the day
Homework stays the focus, but the app should cover the whole day with near-zero-friction switching from every surface. Phase 1 (done): focus/life categories, keep-tracking at countdown end, focus-only goal, fillable day timeline. Phase 2 (done 2026-10-11): presence detection, away/idle prompts, Sleep from away spans in the morning review, weekly "where time went". Phase 2 follow-ups: Settings → Away & Gaps has no per-category "away is expected" list yet (life categories are assumed away-friendly); away spans aren't synced, so iPad doesn't see them. Phase 3: Control Center / Action Button controls + Live Activity built 2026-10-11 (needs Xcode signed in to install, see HANDOFF.md). Still to do: Home Screen widget, Apple Watch app, HomePod via Siri Personal Requests → existing App Intents.

### Future ideas (not started)
- **Screen tracking, next steps**: auto-switch between focus categories (with Undo toast) once suggestion acceptance (`screenSuggest.accepted/declined`) is high; focus→leisure drift should stay a prompt or be logged as distraction, never silently relabel. Let the morning review show "yesterday you worked on…" from screen summaries. User-editable private-app list.
- **All-day voice capture → a model of the user**: record everything the user says through the day (on-device transcription), build it into a long-term understanding of them: what they're learning, thinking about, struggling with. Needs strong privacy design (on-device, opt-in, retention, pause), and ties into the morning review and recall.
- Apple Journal hand-off exists (`JournalShortcut`) but is off: on macOS 26 Journal's Create Entry can't target a specific journal. Revisit when it can (seen in the OS 27 betas).
- Multi-day visual timeline (horizontal blocks for past days)
- Pace-toward-interview indicator (problems remaining ÷ days left)
- Weekly goal in addition to daily
- Editable break sessions (set label like "Lunch", "Gym")
- Notification quick-action to extend +5 min
- Sound customization
