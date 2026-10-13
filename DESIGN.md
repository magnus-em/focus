# Focus design rules

The yardstick for every UI change. A separate reviewer scores screenshots
(`scripts/shots.sh`, light + dark) against this file out of 100 and lists
numbered problems; a change ships at 85+ or after three rounds, with
before/after shots.

## Principles

1. **One hero per surface.** Popover: what's running and for how long.
   Dashboard: today's story (timeline, activity log, focus vs goal). Everything
   else is secondary and visually quieter.
2. **Glass is for the floating layer only** (Apple, Liquid Glass): tab bar,
   timer controls, chips, corner cards, toolbars. Content (cards, lists,
   charts) sits on plain or lightly tinted surfaces. Never glass on glass.
3. **Say it once.** One label per fact. No "FOCUS" + "SWE" + "Sites Blocked" +
   ring stack; no goal shown as both "8.5h / 4h" and "8h 28m".
4. **Color means category.** The running category's color is the accent
   (ring, primary button). Red is for errors and destructive actions only,
   never "you're focusing". Green = goal met / good.
5. **Plain words, no math for the reader.** "58 min past your hour", not
   "60m done · +58m".
6. **Calm by default.** Corner cards are rare, small and never steal focus;
   nothing pops over the user's work.

## Scale

- **Type** (SF Pro, system): 46 hero number · 26 title · 22 stat · 15 button ·
  14 body-strong · 13 body · 12 secondary · 11 caption (uppercase labels:
  11 semibold, +0.3 tracking). Numbers use tabular figures.
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

Category colors come from `categoryColor(_:)`; keep them distinct in
lightness, not only hue.

## SwiftUI rules

- macOS 26: `glassEffect`, `GlassEffectContainer` for things that morph
  (chips ↔ ring on switch), `.buttonStyle(.glass/.glassProminent)` for
  floating controls only. Fallback on 14–15: `.regularMaterial`.
- Content cards: `RoundedRectangle(cornerRadius: 18).fill(.background.secondary)`
  style, not `.glassCard`.
- Every icon-only button has `.help` and an accessibility label; tab icons get
  a visible caption.
- No new hardcoded font sizes outside the scale above.

## Known problems (popover, 2026-10-13)

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
