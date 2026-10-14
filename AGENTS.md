# Agents

Read these before changing anything:

1. `CLAUDE.md`: architecture, every store and view, key behaviours, roadmap. It's written for Claude Code but it's the reference for any agent.
2. `HANDOFF.md`: what's in flight right now and what's next.
3. `DESIGN.md`: before any UI work.

`MORNING_HANDOFF.md`, `FEATURE_PARITY.md`, `IPAD_SETUP.md`, `SHIPPING.md` and `SETUP_CLOUDKIT.md` are older notes; trust `CLAUDE.md` where they disagree.

## Working rules (from the user)

- Commit straight to `main`, never a branch. Solo project.
- Build and install with `./deploy.sh` (never bare `swift build`). Safe while a timer runs: the checkpoint resumes on relaunch. iOS: `./install_ios.sh` with the devices unlocked. Tests: `cd FocusCore && swift test`.
- Never open windows over the user's work. UI screenshots go through `scripts/shots.sh`, which puts them on a hidden virtual display; don't open the Dashboard, review or gallery windows on the real screen unless asked.
- Throwaway SwiftData containers must pass `cloudKitDatabase: .none`, or test rows sync into the user's real data. Delete leaked rows through a `ModelContext`, never raw SQL.
- The repo lives at `~/Code/focus`. Never under `~/Documents` or `~/Desktop` (iCloud evicts files and builds hang).
- No code comments unless the why is non-obvious. Match the surrounding code.
- No duration estimates when proposing work. No recap summaries at the end of replies.
- The user is a Yale CS student prepping for quant + SWE interviews. For non-trivial architectural moves, name the pattern and the trade-off briefly.
- Screen tracking must never switch the user's category on its own except the existing trusted auto-switch with Undo; prompts change nothing unless the user picks.
- When the screen labels go wrong, read `~/Library/Application Support/Focus/prompt-log.jsonl` and `focus://screen-debug` (writes `Focus/screen-debug.json`), find the cause, fix the rule, and note the lesson in `CLAUDE.md`.

Keep `CLAUDE.md` and `HANDOFF.md` current when you land something, so the next agent (Claude Code or Codex) starts from the truth.
