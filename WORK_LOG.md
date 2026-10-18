# Focus implementation work log

## Siri daily totals and Health check status — 2026-10-14

- Siri totals reuse shared day clipping for saved and live work; live duration comes from Claude's fresh activeElapsedSeconds accessor. Break phase is excluded even with a sticky focus label; paused time stays frozen, and the dialog calls it paused. App initialization sets liveEngine for background intents. Invalid/future live time is ignored; saved fetch errors now fail the intent instead of reporting an empty day.
- Four new pure-total regression cases cover midnight, frozen paused input, break/life exclusion, overnight saved work, and invalid/future live input. All 62 core tests pass.
- Apple Health settings show last successful check, outcome/error, and Check now. Import errors no longer masquerade as empty data; pending inserts roll back on failure and concurrent imports are suppressed. Empty readable results do not assert that permission was denied or granted.
- Signed iOS build/install and real-device checks remain pending. No Health samples or live sessions are fabricated for tests; all SwiftData integration checks use explicit in-memory CloudKit-disabled containers.

## Reading definition and time-integrity review — 2026-10-14

- Reading is now educational long-form material. Updated the local model hints and deterministic checks; obvious news/feeds/shopping/forums become Leisure for model proposals, errands Admin. Contradictory old learned/held Reading labels are rejected as uncertain rather than blindly trusted. Casual curiosity alone does not establish Reading. Saved/manual blocks, user checks and learned-label storage are unchanged.
- Added four Reading policy cases for educational formats, non-educational browsing/errands, old learned labels and casual chat. Full core suite passed 58 tests before one additional precedence assertion for account settings.
- Approved Claude's time-integrity fixes through 253079d after code review and an isolated in-memory actual-SessionStore check: merging a pair leaves a third row intact, Undo restores the pair, and a changed displayed pair is refused. This is not a full device round-trip test. Claude owns installation of that change.

## Learned-title guard and morning lifecycle repair — 2026-10-14

- Added pure title-shape checks and raw/lowercase regression examples for timestamp/process/compiler output, terminal commands, code, multiline text and very long strings. Ordinary study topics and Focus source-file titles remain eligible. Targeted policy tests pass.
- Screen learning rejects those keys. Existing suspect entries are retained, excluded from trusted exact matching and few-shot examples, and reviewed with Keep/Remove in Settings → Screen. Keep explicitly re-enables only the stored exact title/category; suspicious titles still cannot become new training examples. Review does not repaint sessions or edit checks.
- Hidden QA of the prior morning build showed no review card. Its onAppear loader was attached to an empty conditional Group; replaced it with a mounted VStack. The gallery fixtures do not change user data. Signed deployment and repeated synthetic visual QA remain pending.
- Reviewed Claude's 735ec23 before installation: requested protection against discarding a newer session on an older remote stop, overwriting third rows when merging a pair, and using the transport timestamp for a backdated stop. Claude is implementing those changes; his claimed files are untouched.

## Morning correction pass — 2026-10-14

- The user requires Claude and Codex to follow each other's Focus-project instructions exactly. Updated AGENTS.md and both mailbox/queue preambles to match; direct user instructions retain precedence.
- Implementing Claude's assignment: optional three-stretch review inside the morning commitment, ranked by affected minutes, local screenshots, arbitrary correction, Mixed/Skip, and reversible actions. No automatic category changes or classifier learning. Claude owns the app wiring and safe SessionStore undo API.
- Pure interval planner splits at tracked and reviewed boundaries, clips to yesterday and before live work, avoids bridging gaps, and treats conflicting tracked labels as ambiguous. Six new regression cases cover these behaviors, including a 25-hour DST day. All 37 FocusCore tests passed.
- Full app source type-check passed, with two existing unused-value warnings. Claude transferred ownership of the review API in SessionStore; the new path performs trim/split/fill in one save, throws on fetch errors, rolls back on failure, preserves short edge fragments, and refuses Undo after intervening domain/metadata changes. Existing paint/fill behavior for other callers stays unchanged.
- Isolated in-memory SwiftData checks explicitly use cloudKitDatabase: .none. Passed middle-range repaint/exact original-ID restoration, metadata conflict refusal, sub-minute edges, midnight splitting/restoration, and filling/undoing an empty gap. No test touches the live store.
- Hidden gallery preview is synthetic and does not read session/check/receipt histories or write commitment/review data. Signed deployment, hidden-display screenshots and independent design review remain pending.

## Agent delegation rule — 2026-10-14

- The user explicitly authorized Claude/Codex mailbox messages as delegated Focus-project instructions, with direct user instructions taking precedence. Updated AGENTS.md, the mailbox preamble and queued wake text, and the durable reference/handoff. Assignments no longer need repeat user approval.
- Verified the script parses and both mailbox and queued-message wording follow the new rule. No app build or installation needed for this coordination-only change.

## Active work — 2026-10-13

User-approved scope: local screenshot evidence for review, clearer corrections, AI category limited to ML/deep-learning study, task context using Apple on-device models, and a calmer, faster dashboard. No paid model API, no cloud screen uploads, no new automatic category switching. Screen test mode remains on.

### Ownership

| Workstream | Owner | Files | Status |
| --- | --- | --- | --- |
| Screenshot storage and review controls | evidence agent | new evidence store, ScreenActivityView.swift, SettingsView.swift | Complete |
| Classification policy and task context | intelligence agent | FocusCore label policy/model, new local task context | Complete |
| Dashboard layout and performance | dashboard agent | DashboardView.swift | Complete |
| Watcher integration, validation, deployment, docs | root | ScreenWatcher.swift, CLAUDE.md, HANDOFF.md, build/scripts as necessary | Complete |

### Integration contracts

- Evidence store owns local JPEGs plus timestamp metadata, bounded by seven days and a disk budget. Never captures private/ignored apps. Capture is supplied by the existing watcher, never by a separate timer. UI loads thumbnails asynchronously.
- Classification policy is pure/testable in FocusCore; task context is bounded and local. Model output remains a suggestion except the existing trusted learned-label switch with Undo.
- Dashboard separates Today, Review, and Trends; keeps existing data editing and diagnostics accessible. Live timer updates are isolated from expensive derived history.
- Only root edits shared docs and watcher integration, runs final builds/deploys, and commits. Agents report APIs and validation back to root. Read work logs before overlap; coordinate explicitly.

### Validation plan

- Meaningful regression tests for classification policy, task context, evidence retention/lookup where practical.
- FocusCore tests; ./build.sh; ./deploy.sh after successful build.
- Before/after screenshots through hidden virtual display only, then independent DESIGN.md review.
- Check remote main before commit because Claude's scheduled tuning also commits there.

### Progress

- Read AGENTS.md, current handoff/design rules, and architecture/roadmap. Working tree clean at start.
- Confirmed installed Mac/SDK are 26.5; use Vision OCR + FoundationModels text context rather than newer unsupported image prompt APIs.
- Known performance suspects: top-level timer observation, repeat history derivation, eager dashboard section stack, 30fps ambient background. Measure where feasible and document limits.

- Screenshot evidence agent delivered local store, async gallery, retention/deletion/privacy gates, and corrections for unknown/mixed/uncertain stretches.
- Intelligence agent delivered AI policy, compact task memory and regression tests. Logs identified assistant-brand and quoted-category contamination; live synthetic tests caught empty-chat hallucination and drove additional guards.
- Dashboard agent delivered Today / Review / Trends, cached day data, isolated live timer, deferred charts and static tint.
- Independent code review fixes: configured-category membership; multiline ML study; unlabeled correction route; generic-title learned-label bypass; invalidate samples and pending screenshot writes on privacy/disable/delete.
- Validation: 27 FocusCore tests pass. Evidence harness passes lookup/filter/downsample/retention/reload/deletion/cancellation/budget checks. Actual on-device synthetic checks verified Focus development → SWE (superseded by the user’s Admin rule) and ML study → AI; remaining calls were delayed and stopped to avoid competing with the tracker. No claim of broad model accuracy.
- Performance: existing live dashboard sample spends substantial main-thread samples recalculating DashboardView/history/charts. Synthetic 15k-session/3k-problem derivation benchmark: 60 refreshes, old2394.72ms/new53.74ms; matching event IDs. This measures derivation only, not a UI speed ratio.
- User requested a prompt wrap-up to reduce usage. Scope frozen; no further agents/model experiments. Final build, brief hidden-display QA, deployment and commit are pending.
- Remote main fetched and matches local starting HEAD; no concurrent Claude commits at this check.

- Final signed release build succeeded; deployment succeeded with backup and 344 sessions preserved before/after.
- Final Today/Review light and dark screenshots captured successfully on the hidden display (.shots/codex-local-after); no real-screen windows opened.
- User requested final wrap-up and updated Markdown for Claude. HANDOFF.md and CLAUDE.md updated; stop further work. Broader design evaluation and real-world accuracy/performance validation are future work.

- Independent design review: Today light 84/100, Review dark 88/100; no clipping found. Light activity timestamps/app names/notes metadata now use Color.secondaryText instead of tertiary to address the reviewer’s contrast finding. Broader real-world tuning remains pending.

- Final contrast correction was rebuilt, signed and deployed successfully; session count remained 344. Source and documentation are ready for the final commit. No further feature work in this session.

- Final independent design check: light dashboard 88/100, dark Review 88/100; no blocking contrast/clipping issue. Final screenshots are .shots/codex-local-final.

- User rule: all Focus-project work in Claude, ChatGPT or Codex is Admin, never homework/SWE/AI. This explicit rule overrides old learned labels and may automatically switch to Admin after sustained active evidence, with Undo; other life-category switches still require a prompt.

- Focus-project Admin rule validated: 27 tests pass, including overrides of stale Math/AI learned labels. Built, signed and deployed; 344 sessions preserved. Automatic Admin switching uses sustained active rule evidence and Undo, and respects pause/class/privacy guards.

## Quick Panel refinement — 2026-10-14

- User chose Quick Panel with the Fitness-style goal ring, daily cumulative focus-category totals above two minutes, existing navigation retained, Dashboard always visible, desktop Details control, and native glass playback buttons shared with Dashboard.
- Official Apple references: WWDC25 “Build a SwiftUI app with the new design” and “Applying Liquid Glass to custom views”. Use public glass/glassProminent, GlassEffectContainer, glassEffectID, matched geometry, symbol replacement; Reduce Motion disables custom transitions. No private Health/Maps UI dependency.
- Today totals use cached saved sessions plus live elapsed work, exclude configured life categories/breaks, clip at calendar-day boundaries, and refresh on store/category/midnight changes. 29 tests pass, including aggregation/live/life exclusion and midnight/future clipping.
- Isolated signed build and deployment passed, preserving 349 sessions. Round 1 review found inactive glass-control contrast; active control state fixed dark mode (90/100). Round 2 light score 84/100 prompted explicit primary foreground on the playback button. Three independent design rounds completed: dark 90/100; light 84/100 still had white prominent text because button style overrode the outer modifier. Final correction sets explicit appearance-dependent color directly on the label. Final signed release deployed successfully with 350 sessions preserved before/after. Root verified the direct-label contrast fix in light mode; final screenshots are `.shots/quick-panel-release`, expanded checks `.shots/quick-panel-final`. No further design rounds or feature work. Concurrent Claude site-blocking commit is included in the final isolated build; only Quick Panel files are committed by Codex.

## Siri, Health, and review contrast — 2026-10-14 (Codex)

- Siri totals use calendar-day clipping, accumulated active seconds and explicit break state; paused totals stay frozen. Background app initialization registers the live engine and starts CloudSyncMonitor before container creation.
- Health Settings reports last successful check, result and errors, with Check now. Query/save errors propagate and pending inserts roll back. Coverage fetch includes older long sessions so imported Health time only fills actual gaps.
- Initial hidden-display design review: learned labels 94/94, morning correction 88/85, switch card 83/83 (light/dark). Fixed faint keyboard hints, distinguished Skip review/Skip stretch, and gave morning category names primary-text contrast with category dots. 63 FocusCore tests pass. Signed iOS build and iPad install at5e01162 succeeded; iPhone unavailable. Claude owns latest-main Mac deploy and second hidden screenshot check. Real Health/Siri checks remain user-driven; no claim of functional authorization/import verification. User flagged the long run; stop additional feature/review work and hand off outstanding visual check to Claude.

## Overnight trust scorecard — 2026-10-14 (Codex)

- Added read-only seven-day scorecard in Dashboard → Review: checked accuracy with sample count, unambiguous interval-weighted tracking agreement, card outcomes, observed-evidence detection delay and auto-switch Undo rate. Existing card-ledger copy no longer calls accepted suggestions correct labels.
- New spans/checks/prompts record test mode; old and unmarked device data remains Earlier data, never inferred from current settings. No timer or history mutations.
- Regression cases cover mode separation, ambiguity/clipping/deduplication, pending/unanswered outcomes and auto-switch Undo denominators. Mac is locked; screenshots deferred until unlocked.

## Overnight next block — 2026-10-14 (Codex)

- Replaced the commitment's guessed exam-study hours with an editable first action, category and optional target. Deterministic planner uses the user's start-with note, then commitment, then nearest exam within the coming week; topic selection stays with the user. Plans are device-local, saved on explicit Start My Day, and visible on Dashboard Today. No timer changes or historic edits.
- Reused the existing evening check-in notification for tomorrow's proposed block; same single request/time/toggle, after commitment review too. Tapping still opens the evening review with its Tomorrow, start with field. No extra alert stream.
- 76 core tests pass, including new planner priority/date-window/no-invented-target cases. App snapshot typecheck passed with two pre-existing unused-value warnings. Claude's scorecard review found no correctness blocker; applied his performance request (cached score, refresh only appear/date/mode/minute). Mac remains locked; hidden visual verification deferred.

- Final overnight validation: Claude reviewed both Codex features (b5560de/938aff6), approved next block, and installed938aff6 on Mac; installed stamp verified. 76 core tests pass. Codex cancelled a duplicate waiting deploy before the install lock to avoid rebuilding the same commit. Screenshot tool exited4 because the Mac is locked; visual acceptance remains pending for morning. Overnight work stopped with well above the requested10% usage reserve.

## Daily Adderall tracking — 2026-10-15 (Codex)

- User requested daily amounts/times and a clear morning dose clock. Adderall now has daily total, first-dose elapsed/start time, latest dose when multiple, explicit actual Taken at entry, dose-time/type edits, seven-day dose/time history and collapsed weekly trends. Timer line opens the dose screen and anchors to first dose each calendar day; later doses do not restart it.
- No synthetic/live dose was logged for the user. Isolated in-memory HealthStore (CloudKit .none) passed totals, date boundaries/future exclusion, earlier timestamp/type edits, persistence reload and delete/Undo semantics. Full app typecheck passed with two existing unused-value warnings. Before screenshots: `.shots/adderall-before`; signed Mac deploy a207e61 succeeded with373 focus sessions before/after. Final screenshots `.shots/adderall-daily`; independent design review: full daily91/92, compact Health88/89, timer89/90 (light/dark). Actual timer shows Log morning dose because none logged today; populated clock visually verified only via synthetic daily view, functional anchor/update semantics via isolated store test.

## Coach evidence foundation — 2026-10-15 (Codex)

- Full OCR journal for user-approved all-category scope, retaining complete recognized text separately from short live classification input. Independent per-file/window baselines plus reconstructable line deltas/hash, 4MiB rotation target, up-to7-day/128MiB bounded retention, async IO, permission-restricted files, partial-tail recovery, and cancellation/deletion. Screenshot IDs returned only after persistence, not invented references.
- Deterministic stretch + exact-interval task grouping; gaps are explicit. Category/metadata prompt echo rejected by pure note-title policy.
- Chrome extension focus report + native-window/title/freshness gating prevents reusing a regular tab report after a private/unobservable switch. Unknown browsers stay local. User must reload extension; no claim of live privacy validation yet.
- Core fixtures passed: long Unicode full text, trailing newlines, missing/corrupt delta bases, rotation/restart/partial-tail recovery, quota/retention, invalidated writes, bundle deletion, browser eligibility, segmentation/duplicate intervals, and title echo. Extension mocked normal/private/NONE/focus-race cases passed; whole app snapshot typecheck passed (two pre-existing unused-value warnings). Review/deploy with Claude pending.

## Coach observation dry-run — 2026-10-15 (Codex)

- Addressed Claude's foundation review: Chrome audio/tab marks and middle-truncated titles accepted only with matching prefix+suffix and all freshness/native-window gates; journal OCR orders detected columns and preserves all recognized text.
- Added meaningful-change policy, bounded persistent metadata queue, source reader with delta/hash checks, structured interpretation/abstention, non-study depth guard, prepared fast→strong routing and derivative deletion. A restarted in-flight request becomes unknown and does not automatically re-send.
- Automatic approval review rejected configurable live wiring because it could permit screenshot/OCR transmission before the first payload review. Safe alternative accepted: hard-coded dry-run only (no defaults override), local preview worker only. No API or Keychain calls by this path. One real, eligible journal/image pair produced an inspectable local preview via the same core prompt builder, with exact image ID/bytes/hash and no content printed to tool outputs.
-118 core tests pass (including Claude's parallel additions); mock Chrome privacy and our journal/episode files typechecked; final whole-app check is blocked only by Claude's parallel CoachDay.Record missing public initializer (reported with the commit). Live sending and clean deployment remain gated on Claude's concrete-payload review and approval review.

- Claude reviewed the actual preview and sent GO LIVE (#91). Added known course context/calendar prefixes and explicit Focus-project Admin rule. Automatic approval review rejected removal of the hard dry-run barrier again, stating delegated approval did not clearly authorize persistent setting + queued scope. No enabling edit executed. Asked the user directly whether to allow new + queued, new only, or keep previews; continue unaffected LeetCode/QA while waiting. No workaround via another agent.

## LeetCode confirmed solve drafts — 2026-10-15 (Codex)

- Deterministic candidate from official problem/submission URL + standalone Accepted result + runtime/memory/result context; excludes private/unknown browser rows and mismatched hashes. Binds URL at capture rather than after OCR/model delay. Confirmation only: confidence and help fields, actual stopwatch at observation or unknown; catalog slug match and per-day dedupe. Native card never steals focus and yields to existing coach/away cards. No API.
- Problem save now returns success and rolls back errors, so confirmation doesn't claim a save or clear the stopwatch on failure. Core detector/timing tests pass; full app source typecheck passed (two existing unused-value warnings). Isolated CloudKit-disabled ProblemStore persistence check passed (explicit insert, SWE/canonical URL, nil unknown time preserved, reload/delete). Synthetic light/dark UI review pending. Galleries added without touching Claude's recall/day code.

## Explicit coach upload approval — 2026-10-15 (Codex)

- User answered the direct scope question: “Enable new observations and queued previews”. Enabled persistent automatic episode processing including queued previews, retaining private/ignored/Focus/incognito/unknown/detected-secret exclusions and shared $5 daily budget. First concrete payload already reviewed by Claude. Optional local dry-run override retained. Claude coordinates the clean-main install and first live ledger check.

- Final whole-app typecheck passed; live commit100a8ea installed by Claude. Hidden QA found an AppKit recursive constraint crash in solve-card galleries while recall galleries rendered. Replaced the optional native picker with explicit confidence buttons and bounded the glass card height to avoid hosting intrinsic-size feedback; retest pending.

- Installed8a48d7d final hidden QA: all6captures succeeded, no solve-card crash. Independent DESIGN.md scores: draft88/89, ready89/90, corrected recall reveal89/89; initial recall87/88. No blockers. Local live status observed18completed episodes and53budget-ledger rows; one unknown outcome safely held without retry. Source typecheck passed100a8ea,123core tests previously passed; final UI fix compiled in Claude's signed deploy. No synthetic user solve/dose entries created.


## Journaling category — 2026-10-16 (Codex)

- User requested Journaling as a category. Added one-time Mac migration appending it to synced category and life lists, preserving existing choices; default life list, shared muted teal color/journal icon and personal-reflection screen-label hint. Existing timer, goal, blocking and device-sync paths handle life categories.
- Validation: 169 FocusCore tests passed; signed clean-main Mac deployment b9e7409 succeeded, 394 sessions before/after. Saved tags and lifeTags both contain Journaling after launch. Hidden before/after popover review passed (light 91, dark 92); menu closed, so screenshots check layout regressions, not selected Journaling appearance. Phone/iPad receive the lists via existing settings sync; device round-trip not exercised.


## Reading and Journaling count as focus — 2026-10-16 (Codex)

- User corrected the initial Journaling life-category assumption and explicitly requested Reading as focus too. Added one-time settings migration removing both from synced lifeTags, ensuring both category names exist, and corrected the Journaling default. Existing saved blocks derive focus status from the category settings.
- Validation: 169 core tests passed. Signed clean-main Mac deployment f049c1a succeeded, preserving 394 sessions; installed defaults confirm the migration completed and neither Reading nor Journaling remains in lifeTags. Device settings sync uses the existing path; device round-trip not exercised.


## Wellbeing group — 2026-10-16 (Codex)

- User approved Wellbeing: Reading, Journaling, Exercise, separate daily totals, prominent category group, no aggregate score/goal. Kept existing non-focus engine behavior through synced lifeTags, with one-time Mac/iOS migration. Mac menu and idle chips distinguish Focus/Wellbeing; daily totals include saved and live time. Phone Now grid groups Focus/Wellbeing/Life and shows each Wellbeing total. Switcher search labels Wellbeing explicitly.
- Verification: core checks passed (including separate Wellbeing accounting). Signed clean-main Mac bf488b7 installed, 398 sessions before/after; migration verified in saved lifeTags. iOS signed builds and final ec2b9cb installed on both iPhone/iPad (iPad connection dropped first attempt, retry succeeded). Hidden Mac review: compact93/94, expanded92/93; iPhone light/dark89/89. Review prompted the final "today’s totals" label. Screenshot folders `.shots/wellbeing-before` / `wellbeing-after`.
- QA incident: existing `-seedDemo` simulator path still enabled Multipeer even with unavailable CloudKit. iPhone simulator3E4EC0CF sent a demo Reading timer, replacing the Mac's Admin interval. Stopped simulators, checked live sync log + predeploy timer state, restored exact 13:31:12.84349–13:57:26.328237 Admin through app `focus://log` (ModelContext edit, sync preserved). Read-only verification confirms Admin restored and no fake Reading row remains for that interval. No demo Math/Sleep rows found in live log. Added compile-time simulator isolation: SwiftData CloudKit `.none`, no Multipeer discovery, no KVS import/export. Both simulators must use those guards before further previews. Simulator3E4EC0CF/A844B04B are test devices, not the user's iPhone8CB600A8/iPad6B62C2FA.

- Final verification after simulator isolation: 170 core checks passed; simulator build succeeded. iPad isolated light/dark review93/93; today's-total heading clear, no clipping. No simulator3E4EC0CF/A844B04B peer traffic observed in the live sync log during the final preview, and restored Admin row remained unchanged. Simulators shut down. Signed native builds remain Mac bf488b7, iOS ec2b9cb; 3fb662e adds simulator-only guards without changing native behavior.


## Phantom 25-hour Math recovery — 2026-10-16 (Codex)

- User reported ~12h focus today. Live store contained a duplicate1500-minute Math block starting10/15 11:53:17.76804, alongside the real71.7-minute block. The long row was absent in the13:52 predeploy backup; the iPad's prior sync log showed that stale session with total90000 (24h runway+1h target). Relaunching the physical iPad during today's install ran `recoverPartialSession` after elapsed exceeded total, which directly inserted total/60 without dedup/peer reconciliation. Deleted exact phantom UUID8A853759-FFDC-4D6F-89BA-FC7343A25ED4 through `focus://unlog`, preserving the legitimate row.
- Removed expired-checkpoint inserts in Mac and iOS engines. Restore positive overtime runway with original countdown target and stale ownership; delayed resume checks the original checkpoint is still pending before starting. Added boundary/multiday/invalid-input checks.
- Verification:173 core checks pass. Actual isolated iPad-engine replay used expired total90000 shared Math checkpoint; runtime log confirmed live total176400, original five saved rows unchanged, no1500-minute insert. Simulator cloud/Multipeer/KVS safeguards retained and simulator shut down. Signed clean-main Mac218cd53 deployed with399 sessions before/after; signed iPhone/iPad218cd53 installs both succeeded. Hidden panel `.shots/recovery-total-check` shows0m focus today, Reading2h46 and Journaling21m separately in Wellbeing. Live store confirms phantom removed and true71.7m Math row retained after relaunch.


## Compact Chrome popup — 2026-10-18 (Codex)

- User screenshots showed the full domain list pushing Dark pages below the popup. Replaced it with a native collapsed disclosure showing the configured site count; expanded list scrolls within120px. Popup320px wide,580px cap;36px mode/time/site buttons, readable secondary colors, mode pressed states and time-field labels. Singular pending-event wording corrected.
- Validation: JavaScript syntax and diff whitespace pass. Isolated headless Chrome (no windows on user's display) loaded the actual HTML/JS/CSS with a mocked extension API:100 sites, blocking AI, one pending event, Night7PM–7AM, per-site action. Light/dark body424px collapsed /548px expanded, no horizontal overflow, bottom action visible; all four modes update selected state and schedule/tuning visibility and emit setDark. Before/after captures `.shots/chrome-popup`. Native gallery screenshot script does not render extension HTML, so browser captures were headless. Mac/iOS builds unnecessary for extension-only assets; unpacked extension reload required.
- Separate visual review scored90/100: no clipping/overlap, readable both themes; optional follow-up polish is blocking-state hierarchy, clearer Mac mode label, and a Dark pages subtitle.


## Dark-page sync, responsiveness and filtering — 2026-10-18 (Codex)

- User reported Mac settings not reaching Chrome, poor filtering, and slow Always switching. Root causes:30s polling, popup read-once UI, dark work sharing the browsing-upload queue, one-center-pixel detection cached per host for7days, API engine missing the extension's maintained fixes.
- Added local20s long polling woken by a Combine settings observer (10ms coalescing), stable configuration revisions +409 rejection of stale offline edits, rapid-edit acknowledgement chaining, independent dark update queue, atomic schedule state and exact boundary alarms. Popup subscribes to storage/page status, removes artificial300ms refresh delays, and names the OS-following mode System.
- Researched official Dark Reader help/contribution/source and Night Eye features/help. Kept dynamic color conversion; bundled Dark Reader4.9.133's2,913 site-fix groups with MIT attribution, source hash and regeneration script. Original-page16-point detection replaces the persistent center-pixel cache; theme/style/navigation/appearance changes recheck native dark pages.
- Verification:6 Node regression tests cover slow-upload isolation, rapid edits, native conflict, live updates, stale reads, and URL rule selection. BrowserBridge typecheck passed; actual isolated bridge on port47822 (stub settings, no data containers) woke a held request in12ms, rejected stale revision409 and wrong Origin403, accepted current revision200. Actual engine in invisible Chrome fixtures passed bright-with-dark-center conversion, native-dark preservation and live theme changes, OS appearance follow, per-site overrides and Off cleanup. Off→Always visible conversion10ms in the final fixture (synthetic, not a claim about all websites). Popup light/dark fixtures passed all modes +incoming settings updates;424px collapsed/548px expanded with100sites. Separate visual review91/100. Shots `.shots/dark-pages-sync` and `.shots/chrome-popup`; headless because native gallery script cannot render extension HTML.
- Live extension install was not automated: branded Chrome disallows unpacked extension loading in the isolated test profile. User Chrome session untouched. Native deployment follows; unpacked extension reload +refresh existing pages still required.
- Coordination: per Claude mailbox request108 (user-approved glyph), replaced MenuBarRing.mark and its doc comment verbatim from agent-bus-state/menubar-mark.swift. Claude owns the matching app-icon files and native deployment after this commit; no duplicate deployment.
