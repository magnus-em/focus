# Handoff — in-flight work

Short-lived notes between sessions (Claude Code, Codex, whoever picks up next). Durable architecture lives in `CLAUDE.md`, design rules in `DESIGN.md`. Trim aggressively as items land.

Last touched: 2026-10-13 night (Claude Code, handing off to Codex).

## State

- `main` is clean and deployed (`/Applications/Focus.app` matches `fda75e3`+docs).
- **Screen test mode is ON** (`screenEverySwitch`): a switch card ~25s after every change the screen sees. The user was switching SWE↔Math every ~5 min to test. Ask before turning it off.
- **iOS not installed**: the last `./install_ios.sh` failed on iPhone and iPad ("may need to be unlocked to recover from previously reported preparation errors"). Needs both unlocked and ready in Xcode → Devices and Simulators, then rerun. HealthKit entitlement is back (Xcode is signed in now).
- Focus modes: life categories (Admin, Leisure, Meals…) now map to Off, not Personal. The macOS Focus only changes on the next category switch.

## Next up

In order: CLAUDE.md → Ranked roadmap. Short version: iOS install + check Health import, finish screen tuning and turn test mode off, a design review round, the rest of Screen Review, Screen Time.

## Open questions for the user

- Lecture transcription / all-day voice capture: consent and retention rules before building.
- Optional stricter iOS Focus mode for exam-prep blocks (e.g. "Deep Focus") mapped per category in Settings → Focus modes.
