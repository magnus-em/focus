# Handoff — in-flight work

Short-lived notes between sessions (Claude Code, Codex, whoever picks up next). Durable architecture lives in `CLAUDE.md`, design rules in `DESIGN.md`. Trim aggressively as items land.

Last touched: 2026-10-14 (Claude Code and Codex both active).

## Active now

| Agent | Task | Files |
| --- | --- | --- |

## Notes

- (Claude → Codex, 10/14) `deploy.sh` now refuses uncommitted source changes and checkouts that don't contain the installed commit (see AGENTS.md). Your 00:28 deploy came from a copy older than the blocking fix and undid it; your 00:32 deploy restored it. Commit the Quick Panel before your next deploy, or it will be refused.
- (Claude, 10/14) Site blocking (hosts + Chrome extension) now runs only while a focus category runs (`TimerManager.shouldBlockSites` uses `isFocusRunning`; relabels re-check it). Leisure was being blocked. Codex's final Quick Panel build includes this committed fix.
- (Claude, 10/14) `project.yml` now has a `VirtualDisplay` framework target: build.sh's provisioning-profile step (xcodebuild, runs when `/tmp/FocusDerivedData` is missing or `Focus.entitlements` is newer) had been failing since the virtual display landed.
- (Claude, 10/14) Live Activity now defaults to focus blocks only (iPhone Settings → Live Activity), with a small Apple Watch layout; it had been on the watch face all day because something is always tracked.

## State

- Codex local tracker update is built and deployed. Scope: screenshot evidence/corrections, local task context and AI safeguards, faster Today / Review / Trends dashboard. See WORK_LOG.md for validation and remaining limits.
- **Screen test mode is ON** (`screenEverySwitch`): a switch card ~25s after every change the screen sees. The user was switching SWE↔Math every ~5 min to test. Ask before turning it off.
- **iOS installed and launched** on both iPhone and iPad during this Codex session. Health import and Siri still need functional checks.
- Focus modes: life categories (Admin, Leisure, Meals…) now map to Off, not Personal. The macOS Focus only changes on the next category switch.

## Next up

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

User selected Quick Panel with the Fitness-style ring retained, daily cumulative focus-only category totals above two minutes, existing navigation retained, Dashboard always visible, a desktop Details button, and native Apple Liquid Glass transport controls shared with the dashboard. Today totals clip midnight boundaries and include live elapsed work. `quickPanelDetails` defaults compact; `popoverExpanded` is legacy. 29 tests pass. See WORK_LOG.md for final build/deployment/visual verification.
