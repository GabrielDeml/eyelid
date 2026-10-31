#!/bin/bash
# Quits a running Insomnia (any copy, by bundle id) and waits for it to exit. Its quit path releases lid mode first
# (applicationShouldTerminate, up to 2 s), so `make install` / `make uninstall` run this before touching the bundle or
# the safety nets (docs/CLOSED_LID.md §9). Never launches the app, and sends the quit only once: a second quit during
# the pending lid release would cut it short. Usage: scripts/quit-running.sh [timeout seconds, default 10]
# Exit 0 = nothing was running, 3 = it was running and has quit, 1 = it is still running.
set -uo pipefail

ID=com.gdeml.Insomnia
TIMEOUT=${1:-10}

running() { [[ "$(/usr/bin/osascript -e "application id \"$ID\" is running" 2>/dev/null)" == true ]]; }

running || exit 0
echo "Quitting Insomnia (it releases lid mode first)…"
/usr/bin/osascript -e "if application id \"$ID\" is running then" \
    -e "with timeout of $TIMEOUT seconds" -e "tell application id \"$ID\" to quit" -e "end timeout" \
    -e "end if" >/dev/null 2>&1 || true
end=$((SECONDS + TIMEOUT))
while running; do
    if (( SECONDS >= end )); then
        echo "Insomnia didn't quit within $TIMEOUT s. Quit it (⋯ ▸ Quit), then try again." >&2
        exit 1
    fi
    sleep 0.2
done
exit 3
