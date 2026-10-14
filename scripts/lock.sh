# Sourced by deploy.sh and install_ios.sh: one install at a time (Mac or iOS),
# across checkouts, worktrees and agents. The script re-runs itself under
# lockf(1), so the kernel holds the lock and drops it when the process exits,
# even on a crash; there's no lock file to take over.
# Usage, before anything else: focus_install_lock "$script_path" "$@"
FOCUS_INSTALL_LOCK="$HOME/Library/Application Support/Focus/install.lock"
focus_install_lock() {
    if [ -n "$FOCUS_INSTALL_LOCKED" ]; then
        echo "$(basename "$1") by ${AGENT_NAME:-someone} from $PWD, started $(date '+%-I:%M %p')" > "$FOCUS_INSTALL_LOCK.owner"
        trap 'rm -f "$FOCUS_INSTALL_LOCK.owner"' EXIT
        return 0
    fi
    mkdir -p "$(dirname "$FOCUS_INSTALL_LOCK")"
    if ! /usr/bin/lockf -k -s -t 0 "$FOCUS_INSTALL_LOCK" true; then
        echo "Waiting for $(cat "$FOCUS_INSTALL_LOCK.owner" 2>/dev/null || echo 'another install') to finish…"
    fi
    export FOCUS_INSTALL_LOCKED=1
    exec /usr/bin/lockf -k -t 1800 "$FOCUS_INSTALL_LOCK" /bin/bash "$@"
}
