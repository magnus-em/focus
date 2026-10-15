#!/bin/zsh
# Runs DayStory.build on a real day (the coach's record, observations,
# screen.json and the SwiftData sessions, read-only) and prints its blocks,
# fixes and courses, to check the Day page against what happened.
#   scripts/day-story-probe/run.sh [YYYY-MM-DD]
# Calendar classes aren't readable from here: pass them as
#   EVENTS="13:05,14:20,MATH 244 Midterm 1;16:00,17:15,CPSC 4770"
# The block the timer is running isn't saved yet, so today's time since it
# started shows as an untracked gap here (the app passes it in).
set -e
day=${1:-$(date +%F)}
here="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp -d)
sqlite3 -readonly ~/Library/Application\ Support/default.store \
  "select cast(ZSTARTTIME+978307200 as real), ZDURATIONMINUTES, coalesce(ZLABEL,''), ZTYPERAW from ZSTOREDWORKSESSION where ZSTARTTIME+978307200 > cast(strftime('%s','$day','-1 day') as integer) order by ZSTARTTIME" > "$tmp/sessions.txt"
(cd "$here" && swift build -q 2>&1 | grep -v "^$" || true)
"$here/.build/debug/storyprobe" "$day" "$tmp/sessions.txt"
rm -rf "$tmp"
