# Handoff — in-flight work

Short-lived notes between sessions (Claude Code, Codex, whoever picks up next). Durable architecture lives in `CLAUDE.md`, design rules in `DESIGN.md`. Trim aggressively as items land.

Last touched: 2026-10-21 (Codex: deep-learning course AI-label corrections).

## Deep-learning course labels — 10/21 (Codex)

- Prompt log and fresh `focus://screen-debug` showed the exact 3Blue1Brown “Attention in transformers · Deep Learning Chapter 6” page repeatedly labeled Leisure. One earlier correct AI classification was also delayed by the window anti-flapping hold.
- A 3:09 PM follow-up then showed SWE: Chrome had shortened “Deep Learning” to “…earning”, defeating the remaining study-word check and rejecting even the user's learned “Still AI” label. Unambiguous attention/transformer title phrases now supply current ML evidence despite middle elision.
- A 3:27 PM Chapter 7 page then exposed another title gap (`How might LLMs store…`, MLP/ReLU/weights and biases), and at 7:21 PM the prompt log showed the exact CPSC 7770 softmax/linear-attention slides repeatedly becoming Math after initially holding AI. Numbered deep-learning chapter titles, LLM questions and attention derivations now provide bounded deterministic evidence.
- Strict visible-ML evidence resolves to AI before learned/cache/model/hysteresis paths. Exact regressions cover the bad Leisure, SWE and Math labels across model/learned/held sources; a Transformers movie trailer remains Leisure and a plain mathematical softmax derivation remains Math. Clean isolated FocusCore suite: 220 pass. Native commit/install details are in `WORK_LOG.md`.

## YouTube focus — 10/21 (Codex)

- Extension 1.2.0 adds Off/During focus/Always controls. During focus follows the app's explicit `isFocus` state, not every running life category. Defaults hide Home recommendations, related videos, Shorts, end-screen suggestions and autoplay; comments remain visible unless selected. Search, Subscriptions, playlists, direct videos and player controls stay available.
- Node logic suite and hidden Chrome Home/watch/Shorts/popup fixture pass; screenshots `.shots/youtube-focus`. Extension-only change: reload Focus Blocker at chrome://extensions, then refresh existing YouTube tabs. Live youtube.com structure still needs a real-use smoke check after reload because the automated fixture is intentionally local.

## Chrome dark pages — 10/18 (Codex)

- Popup compact layout and live settings listeners; direct Mac settings updates, independent mode-change queue, conflict protection for offline/rapid edits, native-theme rechecks and bundled Dark Reader site fixes implemented. Browser fixtures and bridge tests pass; separate visual review91/100.
- Native sync installed at fd1bfeb (448 sessions before/after), live GET /dark verified. Screenshot-reported CSP and optional-image errors fixed in extension1.1.1; strict-policy/separate-world checks passed. Reload Focus Blocker at chrome://extensions and refresh existing pages to pick up new content scripts; deploy.sh installs only native app.

Live claims and agent mail: `scripts/agent status` (see AGENTS.md).

## Screens: Day and Week — 10/15 (start here)

The user picked direction A ("Day story") from https://claude.ai/artifact/TUGjQvhE5CH8LJ4oUzNPSH. Built at 13b5d8a/e746ef2; this evening's follow-up (Claude, side session) at cf7d720, eea155c, 4dbb3c5 and the docs commit after them.
- Model: `FocusCore/DayStory.swift` (+ `DayStoryTests`). UI: `Sources/DayStoryView.swift` (Day page, `SectionTitle`, timeline lanes with hover readout and color key), `Sources/WeekPageView.swift`, `DashboardView.swift`. Popover: `TimerView.swift`, `LockInApp.swift`.
- **User feedback, 10/15 evening:** they hadn't followed the work and "didn't even know what some of them are"; wanted more descriptors and the popover tabs back ("I don't like having to go down More"). Done: tabs Now · Stats · Problems · Notes · Health · More again; every page and section has a title + one-line description; numbers say where they come from; the AI coach is named with an info button. Now DESIGN.md principle 7.
- Design review, three rounds (stopped at the limit): 70 → 77 → **81** (Day 84, Week 85, popover Now 78/76, Problems 80). Shots: `.shots/ia-before/`, `ia-after-2/`, `ia-r1/`, `ia-r2/`, `ia-r3/`; side by side in `.shots/ia-before-after.png`.
- Today's record now rewrites itself after every 2 active hours (max 4/day, `CoachDay.rewriteDue`), so the Day headline keeps up; today's 1 PM v3 record (which still said "untracked continuation" at 11:53) gets replaced on the first tick.
- Real-data check (`scripts/day-story-probe/run.sh`): course minutes were inflated by vague long record entries borrowing a neighbour's course (10/13 CPSC 3231 7h 51m → 78m); fixed with tests, plus one row per fix and topic variants merged. Week now uses the same screen evidence as Day, so its fix counts match (it said 5 for 10/15 while Day said 2).
- **Not done yet:**
  1. Round-3 review leftovers (popover first, it scored lowest): idle popover shows "Ready" with the ring in Math blue and "Today's focus: Math" (say "Ready · Math" and preselect, or neutral ring; move off-task to Details); attention line ranks a 3-minute overlap from yesterday over today's issues (rank by minutes, hide overlaps < 5 min, button that names the outcome); Start looks disabled (prominent, "Start Math"); Day timeline doesn't mark the fix stretches (hatch/⚠ on the lanes, label every calendar block that fits, one gray); legend's look-alike colors (Admin/Chores, Sleep/Break) and an invisible "Nothing logged" swatch; "You tracked Math during your Discrete Math class, 1:05–2:20"; moments repeat the course name and run 3 lines (drop it, cap at 2 with more); one name for tracked time across surfaces ("Your timer" / "Tracked" / "Tracked log" / "Latest stretches"); Problems: "Mark reviewed", neutral Log button, `categoryColor` icons, the "Last 7 days" card (empty, darker, off-scale fonts); Week: timer vs screen as two columns, whole rows clickable, say the headline is computed.
  2. Morning sheet: the correction already lives in the commitment sheet; consider feeding it DayStory's calendar and gap fixes.
  3. Per-stretch screenshots on click (today only the whole-day snapshot zoom under "What the screen saw").
  4. Course pages (direction C) once course attribution has held up for a few weeks.
  5. Exams aren't linked to course codes ("Data Structures Exam 2" has no code, so its course row shows no exam).
- Real data on 10/15: Math ran through MATH 244 Midterm 1 (1:05–2:20) and 2:10–2:53 was unlogged. Both show as fixes on the Day page; the user hasn't acted on them.

## Adderall daily tracking — 10/15

- Daily-first Adderall view, editable actual Taken at timestamps and first-dose morning clock implemented. Isolated CloudKit-disabled HealthStore checks pass (daily mg, prior/future exclusion, edit/reload/delete, later dose preserves first anchor); whole app typecheck passed. Signed Mac deploy at a207e61 succeeded (373 focus sessions before/after). Hidden light/dark design review passed: daily91/92, Health88/89, timer89/90. First-dose populated clock was visually checked in synthetic daily view; actual timer had no dose logged. No dose or time entered on the user's behalf.

## Coach — 10/15 (installed a1dd684)

- Live: screen-text journal (all time), per-screenshot observations to grok-4.3 with grok-4.7 for diagrams/low confidence (user approved new + queued in Codex's chat), day records (grok-4.7 low; 10/09–10/14 back-filled, 10/15 partial, replaced tomorrow), morning recall with study-only cues, digest, 3 questions + "how sure?" + exam debrief, Ask the coach (`focus://coach`), where-was-I line in the popover, LeetCode solve drafts (Codex; hidden QA passed after its picker crash fix). Everything cloud is behind Settings → Coach (on, $5/day). Spend 10/15 by 1 PM ≈ $0.80.
- User to do: reload the Chrome extension (until then every Chrome row is privacy-unknown and excluded from the cloud); rotate the xAI key (it was pasted in chat); answer the MATH 244 midterm debrief tomorrow morning.
- Not exercised end to end: Ask the coach (built, compiled, not clicked), the morning flow with a real record (gallery only), where-was-I with real data (shows only 20+ min after leaving a subject).
- Next (COACH.md ranking): exam coverage → next action, misconception notebook, weekly adjustment.

## Notes

- (User → Codex, 10/14) Claude and Codex must follow each other's instructions exactly for the Focus project, without another user confirmation; resolve unclear or blocked instructions with the sender. Direct user instructions take precedence. Codex is implementing Claude's morning-correction assignment.

- (Claude, 10/14) Agent mailbox approved by Codex after two review rounds (through a42243c). Still to confirm: Codex's hooks are trusted and inject mail automatically in an open chat; Claude's hooks apply from the next Claude session.

- (Claude → Codex, 10/14) `deploy.sh` now refuses uncommitted source changes and checkouts that don't contain the installed commit (see AGENTS.md). Your 00:28 deploy came from a copy older than the blocking fix and undid it; your 00:32 deploy restored it. Commit the Quick Panel before your next deploy, or it will be refused.
- (Claude, 10/14) Site blocking (hosts + Chrome extension) now runs only while a focus category runs (`TimerManager.shouldBlockSites` uses `isFocusRunning`; relabels re-check it). Leisure was being blocked. Codex's final Quick Panel build includes this committed fix.
- (Claude, 10/14) `project.yml` now has a `VirtualDisplay` framework target: build.sh's provisioning-profile step (xcodebuild, runs when `/tmp/FocusDerivedData` is missing or `Focus.entitlements` is newer) had been failing since the virtual display landed.
- (Claude, 10/14) Live Activity now defaults to focus blocks only (iPhone Settings → Live Activity), with a small Apple Watch layout; it had been on the watch face all day because something is always tracked.

## Overnight 10/14 → 10/15

- Codex owns trust scorecard (#9), then next block (#6); Claude owns text log fixes (#7) and possible off-task (#11). No sync/engine edits. Plan: `agent-bus-state/planning/overnight-10-15.md`.
- Trust scorecard (b5560de) and next block (938aff6) are reviewed by Claude and installed on Mac at938aff6; 76 core tests and app typecheck pass. Scorecard uses a one-minute cache. Codex cancelled its duplicate waiting deploy before taking the lock. Hidden screenshot attempt exited4 because Mac locked: visual gate remains pending. When unlocked, run `scripts/shots.sh overnight-final trust-scorecard next-block morning-correction dashboard-review`; one design review pass was the overnight agreement. Keep test mode on and keep old unmarked data separate.
- Overnight scope complete; stop additional work to preserve morning usage. Real Health/Siri and iPhone checks remain user-driven.

## State

- 10/16 stale-checkpoint fix (Codex): removed confirmed phantom 25h Math row from yesterday, leaving real 71.7m row. Both engines now restore overtime without inserting a completed checkpoint; delayed resume respects incoming peer changes. Build/device verification in WORK_LOG.md.

- Codex morning correction pass was signed/deployed at 7fb52b0; hidden QA caught its loader attached to an empty conditional Group. The loader now has a mounted VStack; synthetic light/dark QA needs repeating before calling the feature visually verified. Atomic Undo's isolated CloudKit-disabled checks passed.
- Claude resolved the store incident: iCloud re-imported all old sessions, with 366 total reported (363 old + 3 new); the restriction on opening the live store is lifted. The switch-card outline/keyboard fix is deployed at 9b2d589: ⌃⌥⌘Return accepts the first option, ⌃⌥⌘Delete dismisses, Return/Escape after clicking the card.
- Junk-title learning guard/review landed at 542a0dd; Reading refinement at 848377b. Saved/manual blocks stay unchanged. Mac installed through96296db includes both and the repaired morning loader; synthetic hidden QA passed for learned labels and morning correction. Card shortcut-hint contrast and morning wording/accessibility fixed in5e01162; Claude owns Mac deployment and the final hidden screenshot check.
- Siri's day-clipped active-time total, break/pause audit and Health last-check/result/error + Check now are implemented and core-tested (63 pass). Signed iOS build and iPad installation at5e01162 succeeded. iPhone is unavailable. User-driven Health/Siri response checks remain (Settings → Apple Health → Check now; Siri “How much have I focused today in Focus?”).
- Codex approved Claude's time-integrity changes through 253079d after the newer-session skip, pair-only overlap edits, backdated stop end and stale-pair checks were corrected. Isolated actual-SessionStore checks verified third-row preservation, exact Undo and refusal after the displayed pair changes. Claude handles installation and device round-trip checks.

- Codex local tracker update is built and deployed. Scope: screenshot evidence/corrections, local task context and AI safeguards, faster Today / Review / Trends dashboard. See WORK_LOG.md for validation and remaining limits.
- **Screen test mode is ON** (`screenEverySwitch`): a switch card ~25s after every change the screen sees. The user was switching SWE↔Math every ~5 min to test. Ask before turning it off.
- **iOS installed and launched** on both iPhone and iPad during this Codex session. Health import and Siri still need functional checks.
- Focus modes: life categories (Admin, Leisure, Meals…) now map to Off, not Personal. The macOS Focus only changes on the next category switch.

## Next up

- Wellbeing group approved 10/16: Reading, Journaling, Exercise count up separately and do not count toward focus goals or site blocking. Mac/iOS category grouping, separate daily totals, one-time synced non-focus migration. Verification in WORK_LOG.md.

Landed Codex work: local screenshot evidence and correction controls, task context and AI-category safeguards, and Today / Review / Trends dashboard. See WORK_LOG.md for ownership, validation and remaining work. Keep test mode on. Next: check Health import/device sync and gather user feedback on the updated tracker.

## Open questions for the user

- Lecture transcription / all-day voice capture: consent and retention rules before building.
- Optional stricter iOS Focus mode for exam-prep blocks (e.g. "Deep Focus") mapped per category in Settings → Focus modes.

## Codex wrap-up

- Screenshot review: timestamped local images in triage/activity/timeline, inline enlargement, arbitrary category corrections, Mixed/Unsure without learning; unknown activity is reviewable. Screenshots begin with this build, so older stretches have text only. Settings → Screen has saving/delete controls. Seven-day/256MiB limits; private/ignored apps excluded; queued saves canceled on deletion/disable.
- Local intelligence: Vision OCR + Apple FoundationModels, compact cross-app task memory, reason/uncertainty. AI requires ML/deep-learning evidence; assistant tools alone do not count. Generic chats are not learned and uncertainty cannot trigger switches. Existing trusted auto-switch with Undo preserved. No paid API or screen uploads.
- Dashboard: Today / Review / Trends, optional editable tracked log, cached day data, deferred charts, isolated live timer and static category wash.
- Validation: 27 FocusCore tests, isolated evidence tests (including cancellation), signed release build and ./deploy.sh passed. Deployment backup verified 344 sessions before/after. Before/after hidden screenshots are .shots/codex-local-before and .shots/codex-local-after.
- Remaining: gather actual homework feedback. Two actual-model fixtures passed (Focus development→SWE (superseded by the user’s Admin rule); ML study→AI); the remaining fixture run was stopped after long local-model delays. Do not claim a full accuracy evaluation or measured overall UI speedup. Broader design review and real-world tuning can continue later.
- User asked to stop promptly due usage. Scope frozen. Do not restart agents or extra model experiments automatically. Screen test mode remains on; ask before disabling. Health import, Siri and sync functional checks remain pending.

- Independent design review: Today light 84/100, Review dark 88/100; no clipping found. Light activity timestamps/app names/notes metadata now use Color.secondaryText instead of tertiary to address the reviewer’s contrast finding. Broader real-world tuning remains pending.

- Final contrast correction was rebuilt, signed and deployed successfully; session count remained 344. Source and documentation are ready for the final commit. No further feature work in this session.

- Final independent design check: light dashboard 88/100, dark Review 88/100; no blocking contrast/clipping issue. Final screenshots are .shots/codex-local-final.

- User rule: all Focus-project work in Claude, ChatGPT or Codex is Admin, never homework/SWE/AI. This explicit rule overrides old learned labels and may automatically switch to Admin after sustained active evidence, with Undo; other life-category switches still require a prompt.

## Quick Panel refinement

User said the main screen had become too crowded on 10/21. Compact Now is again only the ring/category/timer, duration choices, one urgent line and Start. Category chips were redundant with the title menu and are gone. Daily focus/wellbeing totals, the LeetCode goal, where-was-I and timeline/log correction are behind Details; zero wellbeing totals stay hidden. An active LeetCode timer/problem keeps one compact action row. Existing navigation and Dashboard remain visible. A one-time preference migration collapses previously expanded panels; the user can reopen Details normally. See WORK_LOG.md for build, test, install and screenshot verification.

- Coach live approval/install verified: user directly selected new + queued observations; installed8a48d7d includes live episode worker and final solve/recall fixes. Local status check observed18completed episodes and53spend-ledger rows; one uncertain request remains unknown without automatic retry. Final screenshots `.shots/coach-solve-fixed` and initial recall `.shots/coach-solve-final`; independent reviewer found no remaining blockers. Chrome extension reload/live browser privacy verification still requires follow-through; unknown windows remain excluded from cloud.

## LeetCode follow-ups — 10/18

- Standalone category/time+problem goals and active-problem workflow are installed at `6293b46`;214 core tests pass, signed install preserved451 sessions, final hidden light/dark review93/100. Durable behavior and file map are in CLAUDE.md, validation in WORK_LOG.md.
- First real-user browser→Done→save walkthrough remains to observe; QA did not insert a synthetic solve or change the user's category. Automatic identity requires a privacy-verified regular LeetCode problem URL; direct catalog selection works independently. Mac-only active-problem UI; no iOS install for this change.
- Goal calibration: starting recommendation120 focused minutes +4 distinct problems/day, roughly3 new (mostly Medium) +1 redo. User has not supplied first interview date or target companies/topics; tailor after those arrive.
