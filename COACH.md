# The Coach: plan (10/15)

Read this first if you're picking up the coach work in a new session. Written by Claude with the user on 10/15 after the morning recall showed nonsense topics.

## What the user wants (their words, paraphrased)

A coach that watches everything on the screen, keeps notes, tracks categories and time (already done), and puts it together into a real understanding of what they did today and when. Next day they can talk it through with it, get quizzed, and recall what they learned. Long term it notices strategic mistakes: time going to the wrong things given their goals (exams, quant + SWE interviews). Maximize intelligence: they have about $1,000 of xAI (Grok) credits and are open to a Claude API key too.

## Why the current recall fails (evidence from 10/14)

`YesterdayRecallView` (`Sources/DayReviewView.swift`, `cueList`) takes the 8 longest activity-log blocks that have notes, from the whole day, and shows their titles. On 10/14 that gave "Corey Veverka's Spreadsheet", "Yale murder case", "Adderall overdose and study concerns", "Category: Admin", "Is Claude Conscious?". Three causes:

1. **Whole day, not study time.** Leisure, Admin and news blocks compete with study blocks.
2. **Titles are window/page titles**, not what was learned ("Array Slicing", "Category: Admin").
3. **Study is fragmented.** C & Systems midterm review was 8 blocks of 2–20 min; Math 244 prep was split the same way.

The notes themselves are often decent (`Focus/screen-notes.json`, written by the on-device model every 90 s per block from page text held in memory): "For a finite poset, X ≤ a(P)·w(P)", "A poset can have several minimal elements and no smallest element". The 3B on-device model is the bottleneck for synthesis, and OCR mangles math, diagrams and handwriting.

## Architecture: layers of memory, each a summary of the one below

| Layer | When | Model | Output |
|---|---|---|---|
| 1. Watch (exists) | Every 15 s | On-device (Apple FoundationModels + Vision OCR) | Category, title, URL, OCR text, local screenshot (`ScreenEvidenceStore`). Drives switch cards and tracking. Stays on-device: instant, free, private. |
| 2. Episodes (new) | Every few minutes of activity, and when a block ends | Fast cloud model with vision (Grok) | One record per stretch of coherent activity: course, task, concepts, activity type, progress/struggle signals, evidence links. |
| 3. Day record (new) | Nightly (and on demand) | Strongest model | Timeline narrative; per-course study digest; quiz questions with answers; plan vs actual; notable drift. |
| 4. Long-term (new) | Weekly + an editable "goals & me" document | Strongest model | Strategic patterns and proposed priorities; the user confirms or edits goals. |
| Conversation (new) | On demand | Strongest model | "What did I get done Tuesday afternoon?", "quiz me on posets", grounded in layers 2–4, citing episodes/screenshots. |

Why this shape: raw screen data for a day is millions of tokens; episodes cut it about a hundredfold, day records again. The expensive model only reads summaries (like map-reduce, or a memory hierarchy). Vision where it matters: math in PDFs, rendered LaTeX, diagrams, handwriting (iPad broadcast frames later).

### Episode record (draft)

```
Episode { id, start, end, device, trackedCategory, course?, task, concepts: [String],
          activity: reading | solving | coding | writing | asking-ai | watching | browsing | admin,
          summary (2–4 sentences), struggle? (stuck on, repeated attempts), evidence: [screenshot ids / titles],
          model, confidence, sentImages: Int }
```
Store locally (`Focus/episodes/YYYY-MM-DD.jsonl`), device-local like screen notes. Day records in `Focus/days/YYYY-MM-DD.json` (+ markdown for reading). "Goals & me" as a user-editable markdown file the strategy pass reads and proposes edits to (never rewrites silently).

### Model routing (one provider layer)

- `CoachModel` protocol: `complete(system:, messages:, images:, schema:)`. Two implementations: **xAI** (OpenAI-compatible chat completions with image input) and **Anthropic** (extend the existing `RecallCoach` client, Keychain `com.magnus.focus.anthropic`). Keys in Keychain only, entered by the user in Settings (agents never enter keys).
- Default: Grok for everything (credits). Per-task override in Settings (episodes / day / strategy / chat).
- **Before wiring: check current xAI model names, image-input support, prices and API data-retention/training policy, and tell the user.** Don't assume model ids.
- Evaluate "maximize intelligence" on real data: run the same day's episodes through Grok and Claude for the day record, show both digests side by side once or twice, let the user pick.

### Cost controls

- Episodes only while active; skip when the screen hasn't meaningfully changed (OCR text diff + same title).
- Text first; attach 1–2 downscaled screenshots per episode only when the text is thin or math/diagram-heavy (heuristics: few OCR words, LaTeX-ish symbols, PDF/Notability/Preview apps).
- Study time (focus categories + educational Reading) gets full episodes; life time gets title/domain-only one-liners, no screenshots.
- Daily cost shown in Settings (tokens and $ per provider), with a daily cap that pauses cloud calls.
- Rough budget: about 100 episode calls/day at a few thousand tokens plus a couple of images each, one big nightly call, one weekly: likely well under $1–3/day. Verify against real prices.

### Privacy

- Never send: private apps (Messages, Passwords, Mail; `ScreenWatcher.privateApps`), ignored apps, incognito, Focus itself.
- Redact before sending: things that look like passwords, API keys, tokens, card numbers (regex pass), email addresses optional.
- Everything stays stored locally; only the minimum goes to the provider per call.
- The user approves the provider and scope in Settings before anything is sent (toggle off by default until they turn it on).

## Phases (each shippable on its own)

0. **Study-only recall, no API (do first).** `YesterdayRecallView` cues from focus-category blocks (+ educational Reading) only; merge blocks of the same course/subject (calendar course codes, MATH → Math, CPSC → SWE); cue = topic from the notes' bullets, not the window title. On-device model may name the topic from bullets. Acceptance: 10/14 would show something like "MATH 244: posets, chains/antichains, counting" and "CPSC 3231: C strings, stack, segfaults", nothing from news/spreadsheets.
1. **Provider layer + Settings.** xAI and Anthropic keys (Keychain), provider per task, data-sent toggle, cost meter + cap. A "Test" button that sends a tiny non-personal prompt.
2. **Episodes.** Built from existing pieces: `ScreenWatcher` spans/notes, in-memory page text, `ScreenEvidenceStore` screenshots. Written when a study block ends and every ~5 min of active study. Shown in the Dashboard activity log under each block.
3. **Day record + digest + quiz.** Nightly at a set time (or at End Day / first open next morning if the Mac slept). Feeds: the morning recall (topics as cues, digest after Reveal), quiz cards into `RecallStore` (user approves), the evening notification.
4. **Ask the coach.** Chat window (and popover entry) over day records + episodes, with citations. Morning: "talk about yesterday".
5. **Strategy.** Weekly pass over day records + goals doc + calendar (exams) + interview targets: misallocations, trends, proposed priorities; shown Sunday and in the Monday commitment. Edits to goals are proposals.

## Who does what (suggested)

- Claude: phase 0, provider layer (phase 1), day record + digest + quiz (phase 3), chat (phase 4).
- Codex: episodes (phase 2): it built the screenshot evidence store, redaction fits there; cost controls.
- Strategy (phase 5) together, once a week of day records exists.
- Coordinate through `scripts/agent` as usual; one review round per feature; deploy clean main.

## Decisions still open (ask the user)

1. Go-ahead to send study-time screenshots + text to xAI (after reporting xAI's data policy).
2. Their xAI API key in Settings (they paste it).
3. Life time: titles only (default) or also episodes?
4. Nightly time for the day record.

## Usage rule

The user is on a Pro plan with extra usage enabled: never run a 5-hour window near its limit, and keep ≥10% for their own work (e.g., morning math review). Prefer fresh sessions for big builds; this plan exists so a new context can start cheaply.
