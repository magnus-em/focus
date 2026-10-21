# Focus design rules

The yardstick for every UI change. A separate reviewer scores screenshots
(`scripts/shots.sh`, light + dark) against this file out of 100 and lists
numbered problems; a change ships at 85+ or after three rounds, with
before/after shots.

## Direction (picked 2026-10-13)

**A + B**: B's "Now" structure (running category as the title, a day strip,
"On screen now", switch chips, one floating control bar) with A's ring as a
compact goal ring beside the big timer. Look and feel: **native Apple, like
the newest iOS Maps and Podcasts**: elegant, minimal, Liquid Glass on the
floating layer, sentence-case titles (no shouty uppercase section labels),
generous whitespace, continuous corners, soft capsules. Mock: "A+B" board in
the directions artifact below.

## Dashboard direction (picked 2026-10-15)

**A, Day story**: the Dashboard has two pages. Day reads like a journal:
the coach's headline, three facts, calendar/you/screen lanes, the day in
blocks with fixes on the row they're about, and a side column for what was
learned. Week holds courses against exams and goals, days to fix, and the
older charts collapsed. Review and Trends are no longer tabs; the popover
lost its Stats tab. Mocks and the three directions:
https://claude.ai/artifact/TUGjQvhE5CH8LJ4oUzNPSH

## Principles

1. **One hero per surface.** Popover: what's running and for how long.
   Dashboard: the day's story (headline, blocks, fixes). Everything
   else is secondary and visually quieter.
2. **Glass is for the floating layer only** (Apple, Liquid Glass): the popover
   panel itself (a Maps-style sheet), the Now Playing bar, corner cards,
   toolbars. Everything inside a glass panel is plain fills (wells, tinted
   capsules), and content cards sit on plain or lightly tinted surfaces.
   Never glass on glass.
3. **Say it once.** One label per fact. No "FOCUS" + "SWE" + "Sites Blocked" +
   ring stack; no goal shown as both "8.5h / 4h" and "8h 28m".
4. **Color means category.** The running category's color is the accent
   (ring, primary button). Red is for errors and destructive actions only,
   never "you're focusing". Green = goal met / good.
5. **Plain words, no math for the reader.** "58 min past your hour", not
   "60m done · +58m".
6. **Calm by default.** Corner cards are rare, small and never steal focus;
   nothing pops over the user's work.
7. **Every screen says what it is.** Each page and section has a title and a
   one-line description in plain words (`SectionTitle`); every number says
   where it comes from (your timer, the screen, the coach). Review new
   screens as someone who has never seen the app (user, 10/15).

## Scale

- **Type** (SF Pro, system): 46 hero number · 26 title · 22 stat · 15 button ·
  14 body-strong · 13 body · 12 secondary · 11 caption (section titles are
  sentence case, 15 semibold, with an optional 12 secondary subtitle). Numbers use tabular figures.
- **Spacing**: 4 · 8 · 12 · 16 · 24 · 32. Popover padding 16, gaps 12–16.
- **Corners** (concentric: inner = outer − padding): popover 26 · cards 18 ·
  wells/toolbars 16–20 · buttons 12–15 · chips full pill.
- **Hit targets**: 44 pt for primary controls, 36+ elsewhere.
- **Contrast**: text 4.5:1 against what's actually behind it (check on glass
  over a busy wallpaper); secondary text no lighter than #5E606B on light,
  #A9AAB4 on dark.

## Color roles

| Role | Light | Dark |
|---|---|---|
| Text | #1B1C21 | #F4F4F6 |
| Secondary text | #5E606B | #A9AAB4 |
| Well (controls inside glass) | rgba(20,24,40,.06) | rgba(255,255,255,.08) |
| Content card | rgba(255,255,255,.55) | rgba(255,255,255,.06) |
| Good | #1F8F55 | #4CD38A |
| Accent | running category's color | same |

Category colors come from `categoryColor(_:)` (FocusCore): focus categories
vivid and far apart (SWE green, Math deep blue, Quant light cyan, AI purple,
HW amber, Class coral), life categories quieter. Keep them distinct in
lightness, not only hue; check new ones against the neighbours in grayscale.

## SwiftUI rules

- macOS 26: `glassEffect`, `GlassEffectContainer` for things that morph
  (chips ↔ ring on switch), `.buttonStyle(.glass/.glassProminent)` for
  floating controls only. Fallback on 14–15: `.regularMaterial`.
- Content cards: `RoundedRectangle(cornerRadius: 18).fill(.background.secondary)`
  style, not `.glassCard`.
- Every icon-only button has `.help` and an accessibility label; tab icons get
  a visible caption.
- No new hardcoded font sizes outside the scale above.

## When information shows (popover)

Categories have three presentation groups: Focus (goal-counting), Wellbeing (Reading, Journaling, Exercise, each with its own daily total), Life. Wellbeing counts up without site blocking and has no combined goal, score or streak; show it above Life and alongside Focus in the idle picker. Keep the existing goal ring focus-only.

Quick Panel (chosen 2026-10-14, simplified 2026-10-21): visible Dashboard action; running category and timer beside the Fitness-style focus-goal ring; duration choices when idle; at most one attention line; native glass Stop / Pause / Resume / Start / Break controls; labeled Details disclosure; Now / Stats / Problems / Notes / Health / More navigation stays visible. Compact default, no drag handle or gesture requirement. Pick the category from the title menu instead of repeating every category as chips. Details holds daily focus and nonzero wellbeing totals, the LeetCode daily goal, where you left off, the day strip and log correction. A compact LeetCode row may surface above Start only while its timer or a problem draft is active.

Use shared `FocusTransportControls` on the panel and dashboard: system `.glass` / `.glassProminent` buttons inside `GlassEffectContainer`, stable `glassEffectID` values, symbol replacement and restrained state transitions. Category totals are plain content capsules, not extra glass layers. Respect Reduce Motion.

## Known problems (popover, 2026-10-13, before the A+B rebuild)

1. Empty band under the tabs; header row crowded, "Yesterday: 0h 19m
   untracked" wraps to three lines.
2. FOCUS / SWE / Sites Blocked / ring all say the same thing.
3. Red ring and red pause during focus read as an alarm.
4. "60m done · +51m" makes the reader do math.
5. Goal shown twice ("8.5h / 4h" and "8h 28m Focus").
6. Five pastel launcher tiles, five colors, cramped labels; orphan "Quit Focus".
7. Unlabeled tab icons; "f(x)" doesn't say Problems.
8. Faint gray-on-glass text; dark mode is a white panel with dark blobs.

## References

Apple Clock and Fitness (rings, big numbers), Things (calm lists), Raycast
(keyboard-first command surface). Directions A (Ring), B (Now), C (Command):
https://claude.ai/artifact/KSWGrRXt5A5qfnpwmQRKx4

## LeetCode practice — 10/18

LeetCode is a separate focus category with its own orange accent and daily timer minutes, not a nested SWE label. Details shows a quiet daily card with problem and focused-time progress, new/redo counts, and explicit Start LeetCode / Choose or log actions. Starting interview-prep targets are4 problems and2 focused hours, editable in Settings. Do not repeat LeetCode minutes in both the daily card and the category capsules; the main goal ring still includes all focus time. Logged solves and tracked time are different evidence and both have labels.

During a known LeetCode problem, the daily card adds its title and work clock, with Done with problem replacing Start. Show Done only for the active problem. Finishing opens the detailed log by user action; merely detecting a page opens nothing. The form labels the outcome, confidence, difficulty/pattern, hints, recorded time and notes, and retains unfinished drafts via Finish later.
