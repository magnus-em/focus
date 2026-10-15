# Handoff — in-flight work

Short-lived notes between sessions (Claude Code, Codex, whoever picks up next). Durable architecture lives in `CLAUDE.md`, design rules in `DESIGN.md`. Trim aggressively as items land.

Last touched: 2026-10-14 (Claude Code and Codex both active).

Live claims and agent mail: `scripts/agent status` (see AGENTS.md).

## Adderall daily tracking — 10/15

- Daily-first Adderall view, editable actual Taken at timestamps and first-dose morning clock implemented. Isolated CloudKit-disabled HealthStore checks pass (daily mg, prior/future exclusion, edit/reload/delete, later dose preserves first anchor); whole app typecheck passed. Signed Mac deploy at a207e61 succeeded (373 focus sessions before/after). Hidden light/dark design review passed: daily91/92, Health88/89, timer89/90. First-dose populated clock was visually checked in synthetic daily view; actual timer had no dose logged. No dose or time entered on the user's behalf.

## Coach build — 10/15

- User approved all-time full-text local journal, then supplied xAI key via Claude; current build is in-app Grok understanding, not the superseded nightly Claude-only proposal. Claude owns xAI client/recall/day model; Codex journal + segmenter first, then episode worker. See mailbox #77–82 and updated coach plan.
- Journal/segmenter/note-title fix and Chrome privacy reports implemented; core tests + app snapshot typecheck pass. Chrome extension reload and live window privacy verification still needed. Foundation0876a85 reviewed; Claude's Chrome title/audio and OCR-column findings are corrected. Core118 tests passed. User directly approved new observations and queued previews to xAI/Grok on 2026-10-15 with the shared $5 budget, resolving the earlier delegated-approval block. Episode worker live by default, opt-in local preview via coachEpisodesDryRun. Course/Admin prompt context is added. Code review and clean-main deployment remain with Claude. Journal format contract is in CLAUDE.md and mailbox #78; read DATE*.jsonl per file, preserve original intervals, skip incognito/unknown and all image-only entries without an eligible journal row. `end` is nominal capture coverage (15s); clip to next observation/cutoff, never fill gaps.

## LeetCode confirmation drafts — 10/15

- Candidate detector + confidence/help confirmation card implemented;123 core tests and app typecheck pass. No real solve was logged for tests. New hidden galleries: leetcode-draft / leetcode-draft-ready. UI review/clean install pending. Claude owns day worker; before any QA deploy, automatic uploads must remain off across both workers while direct user scope choice is pending (the new CoachDayWorker currently auto-generates after90s). Do not route around the upload rejection through a day job.

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

User selected Quick Panel with the Fitness-style ring retained, daily cumulative focus-only category totals above two minutes, existing navigation retained, Dashboard always visible, a desktop Details button, and native Apple Liquid Glass transport controls shared with the dashboard. Today totals clip midnight boundaries and include live elapsed work. `quickPanelDetails` defaults compact; `popoverExpanded` is legacy. 29 tests pass. Signed release deployed with 350 sessions preserved; final compact light/dark screenshots `.shots/quick-panel-release`, expanded `.shots/quick-panel-final`. Native playback label uses explicit appearance-dependent color because prominent style overrides outer foreground. See WORK_LOG.md for verification.
