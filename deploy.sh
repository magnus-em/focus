#!/bin/bash
# deploy.sh — safe install that preserves Focus session data
# Usage: ./deploy.sh (run from repo root) — builds, installs to /Applications, relaunches
set -e
cd "$(dirname "$0")"
source scripts/lock.sh
focus_install_lock "$PWD/$(basename "$0")" "$@"

# Claude Code and Codex deploy from different checkouts. Only install committed
# code that contains whatever is installed now, so one agent's deploy can't
# quietly put back what the other just fixed. FORCE_DEPLOY=1 skips this.
STAMP="$HOME/Library/Application Support/Focus/deployed-commit"
if [ -z "$FORCE_DEPLOY" ]; then
    if [ -n "$(git status --porcelain -- Sources FocusCore VirtualDisplay Package.swift project.yml build.sh)" ]; then
        echo "Uncommitted changes under Sources/FocusCore. Commit first (another checkout's deploy would drop them), or FORCE_DEPLOY=1."
        exit 1
    fi
    if [ -f "$STAMP" ] && ! git merge-base --is-ancestor "$(cat "$STAMP")" HEAD 2>/dev/null; then
        echo "The installed build ($(cut -c1-7 "$STAMP")) isn't in this checkout's history. Rebase onto main first, or FORCE_DEPLOY=1."
        exit 1
    fi
fi

./build.sh
APP="$PWD/.build/app.noindex/Focus.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Old builds left in the repo folder show up as duplicate apps in Spotlight.
for old in Focus.app LockIn.app FocusTimer.app; do
    if [ -d "$old" ]; then
        "$LSREGISTER" -u "$PWD/$old" 2>/dev/null || true
        rm -rf "$old"
        echo "Removed stale $old from repo folder"
    fi
done
for old in /Applications/LockIn.app /Applications/FocusTimer.app; do
    if [ -d "$old" ]; then
        read -r -p "Remove old build $old? [y/N] " ans
        if [ "$ans" = "y" ]; then
            "$LSREGISTER" -u "$old" 2>/dev/null || true
            rm -rf "$old"
        fi
    fi
done

# Sessions live in the SwiftData store (sessions.json was retired in the SwiftData migration).
STORE="$HOME/Library/Application Support/default.store"
BACKUP="$HOME/Library/Application Support/Focus/default.store.pre-deploy-$(date +%Y%m%d_%H%M%S)"
count_sessions() { sqlite3 -readonly "$1" "select count(*) from ZSTOREDWORKSESSION" 2>/dev/null || echo "?"; }

echo "── Pre-install ──────────────────────────────"

if [ -f "$STORE" ]; then
    SESSION_COUNT=$(count_sessions "$STORE")
    # .backup folds the WAL in, unlike a plain cp of the .store file.
    sqlite3 "$STORE" ".backup '$BACKUP'"
    echo "Sessions: $SESSION_COUNT  (backup → $BACKUP)"
else
    echo "No SwiftData store yet"
    SESSION_COUNT=0
fi

echo "── Quitting ──────────────────────────────────"
if pgrep -x Focus > /dev/null 2>&1; then
    # SIGTERM lets the app run willTerminateNotification (saves checkpoint + unblocks sites)
    pkill -TERM -x Focus
    for i in $(seq 1 20); do
        sleep 0.2
        pgrep -x Focus > /dev/null 2>&1 || break
    done
    if pgrep -x Focus > /dev/null 2>&1; then
        echo "Still running — force killing"
        pkill -9 -x Focus
        sleep 0.3
    fi
    echo "Quit."
else
    echo "Not running."
fi

echo "── Installing ───────────────────────────────"
# rm first — cp -r over an existing .app leaves stale files behind
rm -rf /Applications/Focus.app
cp -R "$APP" /Applications/
git rev-parse HEAD > "$STAMP"
"$LSREGISTER" -u "$APP" 2>/dev/null || true

echo "── Verifying ────────────────────────────────"
if [ -f "$STORE" ]; then
    SESSION_COUNT_AFTER=$(count_sessions "$STORE")
    echo "Sessions after: $SESSION_COUNT_AFTER"
    if [ "$SESSION_COUNT_AFTER" != "$SESSION_COUNT" ]; then
        echo "WARNING: session count changed ($SESSION_COUNT → $SESSION_COUNT_AFTER). Backup at $BACKUP"
    fi
else
    echo "No SwiftData store (expected if first run)"
fi

echo "── Launching ────────────────────────────────"
open /Applications/Focus.app
echo "Done."
