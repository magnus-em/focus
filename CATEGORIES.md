# Focus picks the categories: plan (11/13)

Read this first if you're picking up this work. Written by Claude on 11/13. The user asked to "collapse all the categories on Mac so that Focus basically just tracks it all and decides what sort of categories I need and what should be in them." Earlier, on 11/9, they asked for Mac tracking that's so reliable they never change a category by hand.

Nothing here is built yet except step 1's first half: the menu bar reading.

## Where things stand (measured 11/13)

**Who starts blocks on the Mac**, 11/3–11/13, 133 blocks:

| Started by | Blocks | Mostly |
|---|---|---|
| Picked on the Mac (you, or a rule like overnight Sleep) | 65 | AI 24, Math 13, SWE 8, HW 6 |
| A card you accepted | 25 | AI 12, Class 3, Leisure 3 |
| Switched without asking | 22 | Math 6, Leisure 6, SWE 3. Since 11/10, 5 of 24 were undone. |
| The phone or iPad | 21 | Life: Meals, Reading, Chores, Exercise. Some AI. |

You still pick about 6 study blocks a day by hand on the Mac.

**What the Mac can see.** Based on the second-by-second window log, 11/10–11/13, this is the share of tracked time with the Mac in use:

- **Focus categories: 82%.** Math 84%, LeetCode 96%, AI 82%, SWE 59%.
- **Life categories: almost none.** Sleep 2%, Exercise 2%, Chores 0%, Class 13%, Leisure 13%, Meals 45%.

So study happens on the Mac, and most of the rest of the day happens off it.

**How often the screen's label matches the tracked category.** This counts focus time where the screen had a label, 11/3–11/13:

| Category | Match |
|---|---|
| LeetCode | 95% |
| Math | 81% |
| SWE | 79% |
| AI | 69% |
| Admin | 54% |
| HW | 44% |
| Class | 0% (by design: in class it labels the subject, never "Class") |
| **All focus categories** | **73%** |

- **No label** on about a fifth of the focus time it read.
- **Biggest mix-ups:** AI read as SWE (2.1 h), Class read as Math/SWE/AI (2.4 h), Journaling read as Recruiting (1.5 h), HW read as Math.

**What this says:** the screen is good at subjects with a visible marker (LeetCode's site, a course code, math notation). It's weak at categories that describe what kind of time it is rather than the subject: HW, Class, Journaling, Admin. Math homework is both "Math" and "HW", and the screen can only see the Math. It also never sees the off-Mac half of the day.

## The idea: subject plus kind of work

Replace the one hand-picked category with two things Focus fills in itself:

1. **Category** = the subject, proposed by Focus and approved by you once. A first proposal from the data:
   - **Courses:** MATH 244, CPSC 3231, CPSC 4585, CPSC 7770.
   - **Other focus work:** Deep learning on your own (micrograd/makemore), LeetCode, Recruiting.
   - **Life:** Building Focus, Leisure.
   - **Off the Mac:** Class, Sleep, Meals, Exercise, Social, Chores, Commute.
2. **Kind of work** = what you were doing in it: problem set, notes/reading, coding, asking AI, applying.
   - Observations already record this; `practiceShare` and the activity kinds come from it.
   - **HW stops being a category.** Homework becomes "a course + problem set", which is exactly what the put-off Homework goal is about.

Focus vs life stays a property of each category, as today.

## What you'd do on the Mac: two directions

- **A. Nothing to pick.** The timer runs whenever you're at the Mac. The popover shows what Focus thinks you're doing, and you correct it only when it's wrong.
- **B. One switch: Focus on / off (recommended).** You say only whether you mean to work. Focus names the category and keeps switching it as you move between courses.

**Why B:** what you meant is the one thing the screen can't know.
- An ML lecture on YouTube is study in a work block and leisure at midnight.
- A "distraction" only means something against a block you chose to start: the streak, the menu bar count and the "Back to HW?" card all depend on that.
- Put-off goal nudges need to know when you're working.

## Off the Mac: who decides

| Time | Today | After |
|---|---|---|
| Sleep | Away overnight becomes Sleep, with Undo | Same |
| Class | "In class" card | Automatic from the calendar roster, with Undo |
| Exercise | Picked on the phone; Health workouts fill gaps | Health workouts automatic |
| Meals, Social, Chores, Commute | Picked on the phone | Same; if nothing is picked, a gap you can fill later |
| Paper or iPad homework | Timer runs; the screen sees nothing | Focus on + Mac idle = "Off-screen focus". After 15+ min, asks on return, suggesting the last course. |

## Bar to clear before the Mac drops the picker

| Measure | Now | Needed |
|---|---|---|
| Focus time where the screen's category is right (your corrections, or the tracked label) | 73% | 90% |
| Focus time it reads with no label | ~20% | 5% |
| Switches made without asking that you undo | 5 of 24 | 1 in 10 |
| Time to label a new window | ~15 s | Same; watch the menu bar |

## Steps

Each step ships on its own.

1. **See and correct.**
   - The menu bar shows what Focus thinks is in front, next to the streak (built 11/13).
   - Next: under the streak line in the popover, the same reading with a "Wrong?" button, plus a hotkey. The menu bar can't take a click of its own. A correction asks what it was, teaches the window (as the ✗ check does), and goes to `Focus/screen-corrections.jsonl`.
   - Insights gets a daily line with the four measures above.
2. **A course on every reading.** Store the subject (`CoachCourse.resolver`: course code, calendar class, same chat, neighbours) on each screen span next to the category.
   - Uses the on-device resolver and the cloud readings already approved, so it adds no new spend.
3. **Focus proposes the categories.** A "Your categories" section in Insights:
   - It shows the proposed list with hours per week, example windows and which goal each feeds.
   - You approve, rename, merge or split.
   - When a new topic passes 2 h in a week, it asks: "Stat 110: 3 h this week. Make it a category?"
4. **Shadow week.** Focus labels every block with the new categories in the background. The Day page shows its label next to yours, and Insights measures agreement against the bar above.
5. **Switch the Mac to the chosen direction.**
   - The popover drops the category grid for Focus on/off plus what Focus sees.
   - ⌃⌥⌘K stays as start/stop. Picking a category by hand moves into the switcher (⌃⌥⌘J), as an override.
   - Cards between focus categories go away; only switches with Undo remain.
   - Leaving focus for leisure stays a distraction until 8 min, then a switch, backdated (as now).
6. **Goals and Insights by the new categories.** Old rows stay as they are, mapped for charts:
   - HW → the course the screen saw, else "Homework, course unknown".
   - Math → MATH 244 when that was on screen.
7. **Phone.** The life grid stays. Its study grid becomes one Focus button, and the Mac names the category.

## Risks

- **Mistakes nobody sees.** Once you stop picking, nothing contradicts a wrong label. The menu bar reading, corrections and the weekly numbers have to be enough; if agreement drops below the bar, cards come back.
- **Intent.** Only direction B handles it. Under A, every ML video at midnight is study.
- **Losing history.** Old categories stay in old rows; the charts map them rather than rewrite them.
- **Privacy and cost.** Nothing new leaves the Mac. Steps 1–5 add no cloud calls.

## Decisions for the user

1. **A or B.** Recommended: B.
2. **HW becomes "course + problem set"** instead of a category. Recommended: yes.
3. **Who sets the category list:** Focus proposes and you approve (recommended), or fully automatic.
4. **Off-Mac life time:** from the phone, calendar, Health and being away only. The Mac stops offering life categories except Break.
