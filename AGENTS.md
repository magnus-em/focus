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
- Screen tracking must never switch the user's category on its own except the trusted auto-switch with Undo and the user-requested Focus-project → Admin rule, also with Undo; prompts change nothing unless the user picks.
- All work on the Focus project in Claude, ChatGPT or Codex is Admin, never homework/SWE/AI. This explicit preference overrides older learned labels.
- When the screen labels go wrong, read `~/Library/Application Support/Focus/prompt-log.jsonl` and `focus://screen-debug` (writes `Focus/screen-debug.json`), find the cause, fix the rule, and note the lesson in `CLAUDE.md`.

Keep `CLAUDE.md` and `HANDOFF.md` current when you land something, so the next agent (Claude Code or Codex) starts from the truth.

## Two agents, one repo

Claude Code and Codex often work here at the same time, in the same checkout, both committing to `main`.

- **Claim before editing.** Add a row to `HANDOFF.md` → Active now (agent, task, files) before you touch files, and remove it when you've committed. Don't edit files another agent has claimed; if you need one, say so in your row and ask the user.
- **Commit only your files.** `git add <paths>`, never `git add -A` or `git commit -a`. `git status` will show the other agent's unfinished edits; leave them alone.
- **Builds take the whole tree.** `./deploy.sh` and `./install_ios.sh` build whatever is on disk, including the other agent's half-done edits. If anyone else has uncommitted changes under `Sources/`, `FocusCore/` or `FocusPad/`, build from a clean copy instead: `git worktree add --detach <scratch dir> HEAD`, copy your changed files in, run the script there, then `git worktree remove` it.
- **Pull before you commit** (`git pull --rebase`): the other agent and Claude's daily 8:30 tuning task both push to `main`.
- **Read the other agent's commits** (`git log` since you last looked) before building on them. Put problems you find under Notes in `HANDOFF.md` rather than silently rewriting their work.
- **Docs:** `CLAUDE.md` is the durable reference (update the file's row when you change how something works); `WORK_LOG.md` is the dated log of what each session did and validated; `HANDOFF.md` is only the current state, trimmed as things land.
