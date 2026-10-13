#!/bin/zsh
# Screenshots every main screen of the running Focus.app, light and dark, into
# .shots/<label>/ (gitignored) so changes can be looked at before shipping.
#   scripts/shots.sh [label] [view ...]   default label: now, views: all
set -e
# Windows have to be in front for glass to render, so this only runs while
# nobody is using the Mac, and stops at the first keypress or mouse move.
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
need=${SHOTS_IDLE:-120}
if (( $(idle) < need )); then echo "Mac in use (idle $(idle)s < ${need}s); not taking screenshots." >&2; exit 2; fi
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
for v in $views; do
  for mode in light dark; do
    if (( $(idle) < 3 )); then open "focus://gallery-close"; echo "You're back; stopped." >&2; exit 3; fi
    open "focus://gallery?view=$v&dark=$([[ $mode == dark ]] && echo 1 || echo 0)"
    sleep 2.5
    id=$(winid "Gallery $v $mode")
    if [[ -n $id ]]; then screencapture -x -o -l "$id" "$out/$v-$mode.png"; echo "$out/$v-$mode.png"
    else echo "missing: $v $mode" >&2; fi
    open "focus://gallery-close"; sleep 0.5
  done
done
