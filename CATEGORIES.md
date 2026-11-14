# Focus picks the categories: plan (11/13)

Read this first if you're picking up this work. Written by Claude on 11/13. The user asked to "collapse all the categories on Mac so that Focus basically just tracks it all and decides what sort of categories I need and what should be in them." Earlier, on 11/9, they asked for Mac tracking that's so reliable they never change a category by hand.

Built so far: the menu bar reading (step 1, first half) and the seven-group table in code (`FocusCore/CategoryGroups.swift`, `CategoryGroup.of(label)`, tests in `CategoryGroupTests`). Every chart that shows groups reads that one table.

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

## The idea: seven groups that never change, with detail inside

**Update 11/13, the user:** "I don't want a million categories, and I want our old data in whatever we decide, so where time went is shown one consistent way over time." So the top level is fixed and small, and Focus never adds to it on its own.

| Group | Old categories it takes, for all past and future rows | Counts toward focus |
|---|---|---|
| School | HW, Math, SWE, Class | Yes, except Class (as today) |
| Career | Recruiting, LeetCode, Quant | Yes |
| Learning & projects | AI (deep learning, incl. CPSC 7770, and the work you choose) | Yes |
| Wellbeing | Reading, Journaling, Exercise | No |
| Sleep | Sleep | No |
| Life | Meals, Chores, Commute, Admin (incl. building Focus) | No |
| Free time | Leisure, Social, Break | No |

**Every saved block fits:** all 821 since 5/11 (19 old labels), with nothing left over.

**The focus total is unchanged:** the three focus groups hold exactly today's focus categories, so the goal ring, streaks and every past focus total read the same.

The translation is fixed by old category, not guessed per block:
- **Why fixed:** course codes appear in only 1–3% of window titles, so re-sorting old blocks by course would be noise.
- **It matches the goals.** The Homework goal is MATH 244, CPSC 3231 and CPSC 4585; CPSC 7770 already sits with Deep learning.

**Inside a group, Focus fills in the detail itself:**
- **What:** the course or topic (MATH 244, CPSC 3231, makemore, applications…) and the kind of work (problem set, reading, coding, asking AI).
- **Detail is never a category.** It only shows when you open a group (Week page, Insights).
- **Old blocks have no detail,** and say so ("Math, before 11/13").
- **HW stops being picked.** Homework = School time doing problem sets, which is what the put-off goal measures.

**SWE goes to School.** On screen, since 10/14, SWE time was:
- 53% coursework (CPSC 3231 problem sets, CPSC 4585 Pluck homework);
- 12% LeetCode, from before LeetCode was its own category;
- the rest unclear.

Before September, SWE was 7 h in all. Quant was 56 h of May interview prep, so it goes to Career.

### Why these seven (11/13)

**1. The study groups are your goals.**
- School = Homework ("problem sets done early, not the night they're due").
- Career = Recruiting ("land a summer internship, SWE or quant").
- Learning & projects = Deep learning ("CPSC 7770 and building models from scratch").

Research backs tracking progress toward a goal: across 138 experiments, it improved goal attainment (d ≈ 0.40), more so when progress was recorded (Harkin et al. 2016, Psychological Bulletin). So the chart should read as progress on your goals, not a diary of activities.

**2. They split what you skip from what you choose.**
- Your diagnosis (11/9): good at hard technical work you enjoy, failing at homework and recruiting.
- Your request (10/16): a daily minimum on the topics you skip, "so then I can move on to other focus tasks that … are more self-guided and interesting".
- School + Career is the first half, Learning & projects the second.
- In these groups, the week of 11/2 shows it plainly: 31 h of deep learning against 7 h of school work and no Career.
- "Skipped work first, then the work you enjoy" is popular advice with thin direct evidence (reviews of the Premack principle). So Focus should measure whether doing the minimum first changes your totals, not assume it.

**3. The rest of the day in four broad buckets.**
- Time-use practice (BLS American Time Use Survey; Vanderkam's 168-hour log) sorts a week into a few broad groups and compares the totals with what you'd want: sleep, work, chores, exercise, leisure.
- Free time is kept apart from Life because it's the time you choose how to spend: Leisure was 147 h since October, the largest after sleep.
- Wellbeing is your own grouping from 10/16: Reading, Journaling, Exercise.

**4. Some things are not categories at all.** Each of these is its own measure, which is how seven groups stay enough:
- **How you worked** (problem set, reading, coding, asking AI): detail inside a group.
- **What you delivered** (submitted, replied, attended, followed through): the "Outside View" from 11/10, a record of loops, not hours.
- **Messages:** it shows up inside every category. During focus it's a distraction (the streak); toward people it's reply time.
- **Building Focus** stays in Life, as Admin under your rule, shown as detail.


## What you'd do on the Mac: two directions

- **A. Nothing to pick.** The timer runs whenever you're at the Mac. The popover shows what Focus thinks you're doing, and you correct it only when it's wrong.
- **B. One switch: Focus on / off (recommended).** You say only whether you mean to work. Focus names the group and the detail, and keeps switching as you move between courses.

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
3. **The seven groups everywhere.**
   - Week, Insights and the Day page draw the groups, with old rows translated by the table above at read time; nothing is rewritten.
   - Detail (course, kind of work) opens under each group.
   - Goals point at groups plus courses.
4. **Shadow week.** Focus labels every block with a group and detail in the background. The Day page shows its label next to yours, and Insights measures agreement against the bar above.
5. **Switch the Mac to the chosen direction.**
   - The popover drops the category grid for Focus on/off plus what Focus sees.
   - ⌃⌥⌘K stays as start/stop. Picking a category by hand moves into the switcher (⌃⌥⌘J), as an override.
   - Cards between focus categories go away; only switches with Undo remain.
   - Leaving focus for leisure stays a distraction until 8 min, then a switch, backdated (as now).
6. **Retire picking old categories.** The 19 old names stay readable forever, so old rows open, edit and chart. New blocks are saved as a group plus detail.
7. **Phone.** The life grid stays. Its study grid becomes one Focus button, and the Mac names the group.

## Risks

- **Mistakes nobody sees.** Once you stop picking, nothing contradicts a wrong label. The menu bar reading, corrections and the weekly numbers have to be enough; if agreement drops below the bar, cards come back.
- **Intent.** Only direction B handles it. Under A, every ML video at midnight is study.
- **Losing history.** Old categories stay in old rows; the charts translate them with one fixed table, so a week in October and a week in December read the same way.
- **Privacy and cost.** Nothing new leaves the Mac. Steps 1–5 add no cloud calls.

## Decisions for the user

1. **A or B.** Recommended: B.
2. ~~The seven groups and the table above.~~ **Locked by the user on 11/13**, with SWE in School. The top level doesn't grow; a new category gets one of the seven.
3. **HW becomes School + problem set** instead of something you pick. Recommended: yes.
4. **Off-Mac life time:** from the phone, calendar, Health and being away only. The Mac stops offering life categories except Break.
