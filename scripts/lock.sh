# Sourced by deploy.sh and install_ios.sh: one install at a time, across
# checkouts, worktrees and agents. A lock whose process is gone is taken over.
focus_lock() {
    local name="$1" dir="$HOME/Library/Application Support/Focus/$1.lock" waited=0 pid
    mkdir -p "$(dirname "$dir")"
    until mkdir "$dir" 2>/dev/null; do
        pid=$(cat "$dir/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "Taking over a stale $name lock (pid $pid is gone)"
            rm -rf "$dir"
            continue
        fi
        [ $waited -eq 0 ] && echo "Waiting for $(cat "$dir/owner" 2>/dev/null || echo "another $name") to finish…"
        sleep 5
        waited=$((waited + 5))
        if [ $waited -ge 900 ]; then
            echo "Gave up after 15 min waiting for the $name lock ($dir)"
            exit 1
        fi
    done
    echo $$ > "$dir/pid"
    echo "$name by ${AGENT_NAME:-someone} from $PWD, started $(date '+%-I:%M %p')" > "$dir/owner"
    trap "rm -rf \"$dir\"" EXIT
}
