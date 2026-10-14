#!/bin/zsh
# Screenshots every main screen of the running Focus.app, light and dark, into
# .shots/<label>/ (gitignored) so changes can be looked at before shipping.
#   scripts/shots.sh [label] [view ...]   default label: now, views: all
# Windows open on a virtual display off the corner of your screens (see
# DesignGallery.swift), so this runs while you work. SHOTS_VIRTUAL=0 uses your
# real screen instead, and then only while the Mac is idle.
set -e
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
virtual=${SHOTS_VIRTUAL:-1}
need=${SHOTS_IDLE:-120}
waitForView=${SHOTS_WAIT:-3}
if (( ! virtual )) && (( $(idle) < need )); then echo "Mac in use (idle $(idle)s < ${need}s); not taking screenshots." >&2; exit 2; fi
locked=$(swift -e 'import CoreGraphics
print((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int ?? 0)' 2>/dev/null)
if [[ $locked == 1 ]]; then echo "Mac is locked; windows can't be captured until it's unlocked." >&2; exit 4; fi
label=${1:-$(date +%H%M%S)}; shift 2>/dev/null || true
views=("$@")
(( ${#views} )) || views=(popover-0 popover-1 popover-2 popover-3 popover-5 popover-4 dashboard review)
out="$(cd "$(dirname "$0")/.." && pwd)/.shots/$label"
mkdir -p "$out"
winid() {
  swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w["kCGWindowName"] as? String) == CommandLine.arguments[1] { print(w["kCGWindowNumber"]!); break }' "$1" 2>/dev/null
}
trap 'open -g "focus://gallery-close?display=0"' EXIT
for v in $views; do
  for mode in light dark; do
    if (( ! virtual )) && (( $(idle) < 3 )); then echo "You're back; stopped." >&2; exit 3; fi
    open -g "focus://gallery?view=$v&dark=$([[ $mode == dark ]] && echo 1 || echo 0)&virtual=$virtual"
    sleep "$waitForView"
    id=$(winid "Gallery $v $mode")
    if [[ -n $id ]]; then screencapture -x -o -l "$id" "$out/$v-$mode.png"; echo "$out/$v-$mode.png"
    else echo "missing: $v $mode" >&2; fi
    open -g "focus://gallery-close"; sleep 0.5
  done
done
