#!/bin/bash
# Quits every running Insomnia and waits for them to exit. Its quit path releases lid mode first
# (applicationShouldTerminate, up to 2 s), so `make install` / `make uninstall` run this before touching the bundle or
# the safety nets (docs/CLOSED_LID.md §9). Never launches the app, and sends each copy its quit only once: a second
# quit during the pending lid release would cut it short. Copies are found by process (pgrep on the app executable)
# and quit with SIGTERM, which the app routes through its normal quit; a copy only LaunchServices sees (bundle id) gets
# one quit Apple Event. Fails closed: if pgrep can't answer, the copies count as running.
# Usage: scripts/quit-running.sh [timeout seconds, default 10]
# Exit 0 = nothing was running, 3 = it was running and has quit, 1 = it is still running (or that can't be told).
set -uo pipefail

# The overrides exist for the hermetic test only (Tests/InsomniaTests/FixFollowUpTests.swift).
ID=${INSOMNIA_QUIT_TEST_ID:-com.gdeml.Insomnia}
PATTERN=${INSOMNIA_QUIT_TEST_PATTERN:-'/Contents/MacOS/Insomnia$'}
TIMEOUT=${1:-10}

# Sets PIDS to the matching processes. Returns 0 = some, 1 = none, 2 = pgrep failed (can't tell).
find_pids() {
    PIDS=$(/usr/bin/pgrep -f "$PATTERN")
    case $? in 0) return 0 ;; 1) PIDS=""; return 1 ;; *) PIDS=""; return 2 ;; esac
}
# LaunchServices' view (an Insomnia under another executable name). An osascript error adds nothing: pgrep decides.
registered() { [[ "$(/usr/bin/osascript -e "application id \"$ID\" is running" 2>/dev/null)" == true ]]; }
cant_tell() { echo "Can't tell whether Insomnia is running. Quit it (⋯ ▸ Quit), then try again." >&2; exit 1; }

find_pids; found=$?
(( found == 2 )) && cant_tell
if (( found == 1 )); then
    registered || exit 0
fi
echo "Quitting Insomnia (it releases lid mode first)…"
SENT=" "
for pid in $PIDS; do kill -TERM "$pid" 2>/dev/null; SENT+="$pid "; done
if [[ -z "$PIDS" ]]; then
    /usr/bin/osascript -e "if application id \"$ID\" is running then" \
        -e "with timeout of $TIMEOUT seconds" -e "tell application id \"$ID\" to quit" -e "end timeout" \
        -e "end if" >/dev/null 2>&1 || true
fi
end=$((SECONDS + TIMEOUT))
while :; do
    find_pids; found=$?
    (( found == 2 )) && cant_tell
    if (( found == 1 )); then
        registered || exit 3
    fi
    for pid in $PIDS; do   # a copy that started meanwhile gets its one quit too
        [[ "$SENT" == *" $pid "* ]] || { kill -TERM "$pid" 2>/dev/null; SENT+="$pid "; }
    done
    if (( SECONDS >= end )); then
        echo "Insomnia didn't quit within $TIMEOUT s. Quit it (⋯ ▸ Quit), then try again." >&2
        exit 1
    fi
    sleep 0.2
done
