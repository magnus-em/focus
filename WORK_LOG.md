# Focus implementation work log

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
- Validation: 27 FocusCore tests pass. Evidence harness passes lookup/filter/downsample/retention/reload/deletion/cancellation/budget checks. Actual on-device synthetic checks verified Focus development → SWE and ML study → AI; remaining calls were delayed and stopped to avoid competing with the tracker. No claim of broad model accuracy.
- Performance: existing live dashboard sample spends substantial main-thread samples recalculating DashboardView/history/charts. Synthetic 15k-session/3k-problem derivation benchmark: 60 refreshes, old2394.72ms/new53.74ms; matching event IDs. This measures derivation only, not a UI speed ratio.
- User requested a prompt wrap-up to reduce usage. Scope frozen; no further agents/model experiments. Final build, brief hidden-display QA, deployment and commit are pending.
- Remote main fetched and matches local starting HEAD; no concurrent Claude commits at this check.

- Final signed release build succeeded; deployment succeeded with backup and 344 sessions preserved before/after.
- Final Today/Review light and dark screenshots captured successfully on the hidden display (.shots/codex-local-after); no real-screen windows opened.
- User requested final wrap-up and updated Markdown for Claude. HANDOFF.md and CLAUDE.md updated; stop further work. Broader design evaluation and real-world accuracy/performance validation are future work.

- Independent design review: Today light 84/100, Review dark 88/100; no clipping found. Light activity timestamps/app names/notes metadata need stronger contrast (use Color.secondaryText instead of tertiary). Left as a bounded follow-up rather than restarting a release build; broader real-world tuning remains pending.
