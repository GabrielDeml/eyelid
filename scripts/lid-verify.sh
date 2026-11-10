#!/bin/bash
# Read-only lid-mode checks (docs/DESIGN.md "Verify"). Never uses sudo, never registers anything,
# never changes a power setting. Usage:
#   scripts/lid-verify.sh [path/to/Eyelid.app]       (default /Applications copy)
#   scripts/lid-verify.sh --staged <path>            signatures, daemon plist and root ownership only; exit 1 on any
#                                                    failure (`make install` runs this on its root-owned staged copy)
set -uo pipefail

STAGED=0
if [[ "${1:-}" == "--staged" ]]; then STAGED=1; shift; [[ -n "${1:-}" ]] || { echo "--staged needs a path"; exit 2; }; fi
APP="${1:-/Applications/Eyelid.app}"
HELPER="$APP/Contents/MacOS/EyelidHelper"
PLIST="$APP/Contents/Library/LaunchDaemons/com.gdeml.Eyelid.helper.plist"
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
info() { printf '  · %s\n' "$*"; }

[[ -d "$APP" ]] || { echo "no app at $APP"; exit 2; }
echo "Eyelid lid-mode checks for $APP"

echo "Signatures"
APP_INFO=$(codesign -dvvv "$APP" 2>&1)
HELPER_INFO=$(codesign -dvvv "$HELPER" 2>&1)
TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_INFO")
[[ -n "$TEAM" && "$TEAM" != "not set" ]] && ok "team $TEAM" || bad "no Team ID (unsigned build)"
# Any flags word that includes "runtime" (e.g. 0x10000(runtime), or 0x10002(adhoc,runtime) on an ad-hoc build).
RUNTIME_RE='flags=0x[0-9a-f]+\([^)]*runtime'
grep -Eq "$RUNTIME_RE" <<<"$APP_INFO" && ok "app: hardened runtime" || bad "app: no hardened runtime"
grep -Eq "$RUNTIME_RE" <<<"$HELPER_INFO" && ok "helper: hardened runtime" || bad "helper: no hardened runtime"
grep -q '^Identifier=com.gdeml.Eyelid.helper$' <<<"$HELPER_INFO" && ok "helper identifier com.gdeml.Eyelid.helper" \
    || bad "helper identifier is not com.gdeml.Eyelid.helper"
for b in "$APP" "$HELPER"; do
    name=$([[ "$b" == "$APP" ]] && echo app || echo helper)
    codesign -d --entitlements - "$b" 2>/dev/null | grep -q get-task-allow && bad "$name has get-task-allow" \
        || ok "$name: no get-task-allow"
done
codesign --verify --strict --deep "$APP" 2>/dev/null && ok "bundle seal valid" || bad "bundle seal invalid"
if [[ -n "$TEAM" && "$TEAM" != "not set" ]]; then
    # The requirements each side pins at runtime (HelperInfo.clientRequirement / helperRequirement). The helper adds
    # `and cdhash H"<installed app>"` to the client one at start-up (docs/DESIGN.md "Security").
    req() { echo "identifier \"$1\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"; }
    codesign --verify -R="$(req com.gdeml.Eyelid)" "$APP" 2>/dev/null && ok "app passes the client requirement" \
        || bad "app fails the client requirement"
    codesign --verify -R="$(req com.gdeml.Eyelid.helper)" "$HELPER" 2>/dev/null && ok "helper passes the helper requirement" \
        || bad "helper fails the helper requirement"
fi

echo "Daemon plist"
if [[ -f "$PLIST" ]]; then
    PINNED=$(plutil -extract 'SpawnConstraint.cdhash.$in.0' raw -o - "$PLIST" 2>/dev/null | base64 -d | xxd -p | tr -d '\n')
    ACTUAL=$(sed -n 's/^CDHash=//p' <<<"$HELPER_INFO")
    [[ "$PINNED" == "$ACTUAL" ]] && ok "SpawnConstraint pins the bundled helper ($ACTUAL)" || bad "pinned $PINNED != helper $ACTUAL"
    pval() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
    [[ "$(pval RunAtLoad)" == "true" ]] && ok "RunAtLoad (boot reset)" || bad "RunAtLoad is not true: no boot reset"
    [[ "$(pval KeepAlive:SuccessfulExit)" == "false" ]] && ok "KeepAlive { SuccessfulExit = false }" \
        || bad "KeepAlive is not { SuccessfulExit = false }"
else
    bad "no daemon plist (not built by scripts/build.sh)"
fi

echo "Install location (root-owned, no group/other write, no ACLs)"
if [[ "$APP" == "/Applications/Eyelid.app" || $STAGED -eq 1 ]]; then
    bad_items=$(find "$APP" \( ! -user root -o -perm -g+w -o -perm -o+w -o -acl \) -print 2>/dev/null | head -5)
    [[ -z "$bad_items" ]] && ok "every item owned by root, not group/other-writable, no ACL" || bad "unsafe items: $bad_items"
else
    info "not /Applications/Eyelid.app: lid-mode setup is refused from here (expected for build/)"
fi

if [[ $STAGED -eq 1 ]]; then exit $fail; fi

echo "Registration"
STATUS=$("$APP/Contents/MacOS/Eyelid" --helper-status 2>/dev/null); rc=$?
info "SMAppService: $(head -1 <<<"${STATUS:-?}") (exit $rc)"
# The second line says whether the helper answers this copy (it answers only the installed app it pinned).
[[ -n "$(sed -n 2p <<<"$STATUS")" ]] && info "$(sed -n 2p <<<"$STATUS")"

echo "Power state"
ioreg -r -c IOPMrootDomain -d 1 | grep -E '"(SleepDisabled|AppleClamshellState)"' | sed 's/^ */  · /'
pgrep -x EyelidHelper >/dev/null && info "EyelidHelper running (pid $(pgrep -x EyelidHelper))" || info "EyelidHelper not running"
pmset -g assertions 2>/dev/null | grep -i eyelid | sed 's/^ */  · /' || true

exit $fail
