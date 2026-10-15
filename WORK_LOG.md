# Focus implementation work log

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
