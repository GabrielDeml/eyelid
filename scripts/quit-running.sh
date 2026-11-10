#!/bin/bash
# Quits every running Eyelid and waits for them to exit. Its quit path releases lid mode first
# (applicationShouldTerminate, up to 2 s), so `make install` / `make uninstall` and the pkg's preinstall run this before
# touching the bundle or the helper. Never launches the app, and sends each copy its quit only once: a second
# quit during the pending lid release would cut it short. Copies are found by process (pgrep on the app executable,
# with or without arguments: a copy started from a terminal runs as `Eyelid --gui`) and quit with SIGTERM, which the
# app routes through its normal quit; a copy only LaunchServices sees (bundle id) gets one quit Apple Event. Any app
# can have an executable named Contents/MacOS/Eyelid, so a process whose bundle ID reads as someone else's is left
# alone. As root (the pkg's preinstall) only the copy being replaced counts, judged by the executable the kernel has
# mapped, and there are no Apple Events (see ours() and registered()). Fails closed: if pgrep or lsof can't answer, the
# copies count as running, and as a user a copy whose bundle ID can't be read counts as ours.
# --insomnia quits the app's old name instead (bundle ID com.gdeml.Insomnia: v1 and pre-rename builds, wherever they
# run), so `make install` / `make uninstall` remove what those set up only after their quit has released the flag. The
# same bundle-ID check leaves any other app named Insomnia alone. Refused as root, where a process counts by its path
# alone and /Applications/Insomnia.app may be someone else's app.
# Usage: scripts/quit-running.sh [--insomnia] [timeout seconds, default 10]
# Exit 0 = nothing was running, 3 = it was running and has quit, 1 = it is still running (or that can't be told).
set -uo pipefail

NAME=Eyelid
ID=com.gdeml.Eyelid
if [[ "${1:-}" == --insomnia ]]; then
    (( EUID != 0 )) || { echo "--insomnia can't be used as root" >&2; exit 1; }
    NAME=Insomnia ID=com.gdeml.Insomnia
    shift
fi
# Test hooks: override the bundle id and process pattern.
ID=${EYELID_QUIT_TEST_ID:-$ID}
PATTERN=${EYELID_QUIT_TEST_PATTERN:-"/Contents/MacOS/$NAME( |\$)"}
TIMEOUT=${1:-10}

# Sets PIDS to the matching processes that are ours. Returns 0 = some, 1 = none, 2 = pgrep or lsof failed (can't
# tell).
find_pids() {
    PIDS=$(/usr/bin/pgrep -f "$PATTERN")
    case $? in 0) ;; 1) PIDS=""; return 1 ;; *) PIDS=""; return 2 ;; esac
    local pid mine="" rc
    for pid in $PIDS; do
        ours "$pid"; rc=$?
        case $rc in 0) mine+="$pid " ;; 1) ;; *) PIDS=""; return 2 ;; esac
    done
    PIDS=$mine
    [[ -n "$PIDS" ]]
}
# As root, trust nothing another user controls: argv (what pgrep and ps report) can name any path, so a process
# counts only if lsof shows the installed app's executable mapped as its text, and no path from argv is ever opened.
# Copies elsewhere (build/) don't matter there: lid mode only runs from /Applications. Returns 2 if lsof says nothing
# about a process that is still alive.
# As a user, skip a process only when its bundle ID was read and isn't ours. ps gives the path it was started as (what
# pgrep matched); anything that isn't a path inside a bundle counts as ours.
INSTALLED_EXE=/Applications/Eyelid.app/Contents/MacOS/Eyelid
ours() {
    local exe id
    if (( EUID == 0 )); then
        exe=$(/usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null)   # captured first: grep -q would SIGPIPE lsof
        if [[ -z "$exe" ]]; then kill -0 "$1" 2>/dev/null && return 2; return 1; fi
        /usr/bin/grep -qxF "n$INSTALLED_EXE" <<<"$exe"
        return
    fi
    exe=$(/bin/ps -o comm= -p "$1" 2>/dev/null)
    [[ "$exe" == /*/Contents/MacOS/* ]] || return 0
    # PlistBuddy prints "File Doesn't Exist" on stdout when there's no Info.plist: only its success counts.
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${exe%/Contents/MacOS/*}/Contents/Info.plist" \
        2>/dev/null) || return 0
    [[ -z "$id" || "$id" == "$ID" ]]
}
# LaunchServices' view (an Eyelid under another executable name). An osascript error adds nothing: pgrep decides.
# Never as root (the pkg's preinstall), so no quit Apple Event either: root has no GUI session, and an Apple Event to
# the user's app could hang or fail.
registered() {
    (( EUID != 0 )) || return 1
    [[ "$(/usr/bin/osascript -e "application id \"$ID\" is running" 2>/dev/null)" == true ]]
}
cant_tell() { echo "Couldn't check whether ${NAME} is running. Quit it from its panel, then try again." >&2; exit 1; }

find_pids; found=$?
(( found == 2 )) && cant_tell
if (( found == 1 )); then
    registered || exit 0
fi
echo "Quitting ${NAME}…"
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
        echo "${NAME} didn't quit within $TIMEOUT seconds. Quit it from its panel, then try again." >&2
        if (( EUID == 0 )); then   # under Installer the copy may belong to another logged-in user
            left=${PIDS% }
            echo "Still running for: $(/bin/ps -o user= -p "${left// /,}" 2>/dev/null | sort -u | tr '\n' ' ')" >&2
        fi
        exit 1
    fi
    sleep 0.2
done
