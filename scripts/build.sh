#!/bin/bash
# Build, assemble, sign and verify build/Insomnia.app (docs/DESIGN.md "Build and install").
#
#   scripts/build.sh                         sign with the first "Apple Development" identity (lid mode: helper)
#   INSOMNIA_SIGN_IDENTITY="…" scripts/build.sh   sign with a specific identity
#   INSOMNIA_SIGN_KEYCHAIN=~/Library/Keychains/insomnia.keychain-db   optional locked signing keychain
#
# Never installs anything, never needs sudo. `make install` is the separate, explicit step.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP_NAME=Insomnia
BUNDLE_ID=com.gdeml.Insomnia
HELPER_ID=com.gdeml.Insomnia.helper
HELPER_PLIST_NAME=com.gdeml.Insomnia.helper.plist
HELPER_TEMPLATE="$ROOT/Resources/$HELPER_PLIST_NAME.in"
INSTALLED=/Applications/Insomnia.app
OUT="$ROOT/build/$APP_NAME.app"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Identity ---------------------------------------------------------------------------------------------------------
ID="${INSOMNIA_SIGN_IDENTITY:-}"
if [[ -z "$ID" ]]; then
    ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
    [[ -n "$ID" ]] || die "no 'Apple Development' signing identity found (security find-identity -v -p codesigning)."
fi
[[ "$ID" != "-" ]] || die "ad-hoc builds aren't supported: lid mode needs a signed helper."

# An explicitly named identity must exist before we spend a full compile on it.
IDENTITIES=$(security find-identity -v -p codesigning ${INSOMNIA_SIGN_KEYCHAIN:+"$INSOMNIA_SIGN_KEYCHAIN"} || true)
grep -Fq -- "$ID" <<<"$IDENTITIES" || die "signing identity '$ID' not found (security find-identity -v -p codesigning)"

# A locked keychain is unlocked only around the codesign steps (6-8), so other code running as you has the shortest
# window to sign with it (docs/DESIGN.md "Security").
KEYCHAIN_ARGS=()
[[ -n "${INSOMNIA_SIGN_KEYCHAIN:-}" ]] && KEYCHAIN_ARGS=(--keychain "$INSOMNIA_SIGN_KEYCHAIN")
lock_keychain() { [[ -n "${INSOMNIA_SIGN_KEYCHAIN:-}" ]] && security lock-keychain "$INSOMNIA_SIGN_KEYCHAIN" || true; }
say "Signing identity: $ID"

# 2. Compile ------------------------------------------------------------------------------------------------------------
say "swift build -c release"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
[[ -x "$BIN/$APP_NAME" && -x "$BIN/InsomniaHelper" ]] || die "build products missing in $BIN"

# 3. Assemble fresh in a staging dir (never copy onto an existing signed binary) --------------------------------------
mkdir -p "$ROOT/build"
STAGE=$(mktemp -d "$ROOT/build/.stage.XXXXXX")
cleanup_stage() { rm -rf "$STAGE"; }
trap 'cleanup_stage; lock_keychain' EXIT
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
ditto "$BIN/InsomniaHelper" "$APP/Contents/MacOS/InsomniaHelper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 4. Icon: drawn in code, exported headless ---------------------------------------------------------------------------
say "Rendering AppIcon.icns"
ICONSET="$STAGE/AppIcon.iconset"
"$BIN/$APP_NAME" --export-icon "$ICONSET"   # run the build product, never the copy we will sign
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 5. Strip rpaths; only system libraries may be linked; record the real SDK ----------------------------------------
# SwiftPM stamps LC_BUILD_VERSION with sdk = the deployment target (14.0). AppKit picks "linked on or after" behaviour
# from that value, so stamp the SDK we actually compiled against (macOS 27 SDK) before signing.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
MIN_OS=$(sed -n 's/.*platforms: \[\.macOS(\.v\([0-9]*\))\].*/\1.0/p' "$ROOT/Package.swift")
[[ -n "$SDK_VERSION" && -n "$MIN_OS" ]] || die "could not read the SDK version or the deployment target"
for b in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/InsomniaHelper"; do
    vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$b" "$b"
    while read -r rp; do
        [[ -n "$rp" ]] && install_name_tool -delete_rpath "$rp" "$b"
    done < <(otool -l "$b" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
    if otool -l "$b" | grep -q LC_RPATH; then die "$(basename "$b") still has an LC_RPATH"; fi
    bad=$(otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/)' || true)
    [[ -z "$bad" ]] || die "$(basename "$b") links non-system libraries: $bad"
done

# 6. Sign the helper (explicit identifier: SwiftPM's own signature says "InsomniaHelper") -----------------------------
if [[ -n "${INSOMNIA_SIGN_KEYCHAIN:-}" ]]; then
    say "Unlocking signing keychain $INSOMNIA_SIGN_KEYCHAIN"
    security unlock-keychain "$INSOMNIA_SIGN_KEYCHAIN"
fi
say "Signing helper"
codesign --force --options runtime --timestamp=none --identifier "$HELPER_ID" "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" \
    --sign "$ID" "$APP/Contents/MacOS/InsomniaHelper"

# 7. Launchd plist: Team ID + the signed helper's cdhash pinned in a SpawnConstraint.
[[ -f "$HELPER_TEMPLATE" ]] || die "missing $HELPER_TEMPLATE"
say "Filling the helper's launchd plist"
INFO=$(codesign -dvvv "$APP/Contents/MacOS/InsomniaHelper" 2>&1)
TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$INFO")
CDHASH=$(sed -n 's/^CDHash=//p' <<<"$INFO")
[[ -n "$TEAM" && "$TEAM" != "not set" && -n "$CDHASH" ]] || die "could not read the helper's TeamIdentifier / CDHash"
CDHASH_B64=$(xxd -r -p <<<"$CDHASH" | base64)
mkdir -p "$APP/Contents/Library/LaunchDaemons"
sed -e "s|__TEAM_ID__|$TEAM|g" -e "s|__HELPER_CDHASH_BASE64__|$CDHASH_B64|g" "$HELPER_TEMPLATE" \
    > "$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST_NAME"
plutil -lint "$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST_NAME" >/dev/null

# 8. Sign the app (no --deep; seals Info.plist and the daemon plist) ---------------------------------------------------
say "Signing app"
codesign --force --options runtime --timestamp=none "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" --sign "$ID" "$APP"
lock_keychain

# 9. Verify ---------------------------------------------------------------------------------------------------------------
say "Verifying"
codesign --verify --strict --deep "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
for b in "$APP" "$APP/Contents/MacOS/InsomniaHelper"; do
    ents=$(codesign -d --entitlements - "$b" 2>/dev/null || true)
    for forbidden in get-task-allow disable-library-validation allow-dyld-environment-variables \
                     allow-unsigned-executable-memory disable-executable-page-protection allow-jit; do
        if grep -q "$forbidden" <<<"$ents"; then die "$(basename "$b") carries the forbidden entitlement $forbidden"; fi
    done
done
APP_INFO=$(codesign -dvvv "$APP" 2>&1)
HELPER_INFO=$(codesign -dvvv "$APP/Contents/MacOS/InsomniaHelper" 2>&1)
APP_TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_INFO")
HELPER_TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$HELPER_INFO")
[[ -n "$APP_TEAM" && "$APP_TEAM" != "not set" && "$APP_TEAM" == "$HELPER_TEAM" ]] \
    || die "TeamIdentifier mismatch (app '$APP_TEAM', helper '$HELPER_TEAM')"
grep -q 'flags=0x10000(runtime)' <<<"$APP_INFO" || die "app is not signed with the hardened runtime"
grep -q 'flags=0x10000(runtime)' <<<"$HELPER_INFO" || die "helper is not signed with the hardened runtime"
# The requirements each side pins at runtime (HelperInfo.clientRequirement / helperRequirement); the helper adds the
# installed app's cdhash to the client one at start-up.
req() { echo "identifier \"$1\" and anchor apple generic and certificate leaf[subject.OU] = \"$APP_TEAM\" and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"; }
codesign --verify -R="$(req "$BUNDLE_ID")" "$APP" || die "app fails the client requirement"
codesign --verify -R="$(req "$HELPER_ID")" "$APP/Contents/MacOS/InsomniaHelper" || die "helper fails the helper requirement"
# The daemon plist must pin exactly the helper we ship (signing the app doesn't touch the helper: no --deep).
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST_NAME"
[[ -f "$DAEMON_PLIST" ]] || die "signed build without the helper's launchd plist"
plutil -lint "$DAEMON_PLIST" >/dev/null
pval() { /usr/libexec/PlistBuddy -c "Print :$1" "$DAEMON_PLIST" 2>/dev/null || true; }
[[ "$(pval Label)" == "$HELPER_ID" ]] || die "daemon plist Label is not $HELPER_ID"
[[ "$(pval "MachServices:$HELPER_ID")" == "true" ]] || die "daemon plist doesn't publish the $HELPER_ID Mach service"
[[ "$(pval BundleProgram)" == "Contents/MacOS/InsomniaHelper" ]] || die "daemon plist BundleProgram isn't the helper"
[[ "$(pval KeepAlive:SuccessfulExit)" == "false" ]] || die "daemon plist KeepAlive must be { SuccessfulExit = false }"
[[ "$(pval RunAtLoad)" == "true" ]] || die "daemon plist RunAtLoad must be true (the boot reset depends on it)"
[[ "$(pval SpawnConstraint:team-identifier)" == "$APP_TEAM" ]] || die "SpawnConstraint team-identifier != $APP_TEAM"
[[ "$(pval SpawnConstraint:signing-identifier)" == "$HELPER_ID" ]] || die "SpawnConstraint signing-identifier != $HELPER_ID"
FINAL_CDHASH=$(sed -n 's/^CDHash=//p' <<<"$(codesign -dvvv "$APP/Contents/MacOS/InsomniaHelper" 2>&1)")
PINNED_CDHASH=$(plutil -extract 'SpawnConstraint.cdhash.$in.0' raw -o - "$DAEMON_PLIST" 2>/dev/null | base64 -d | xxd -p | tr -d '\n')
[[ -n "$FINAL_CDHASH" && "$PINNED_CDHASH" == "$FINAL_CDHASH" ]] \
    || die "SpawnConstraint cdhash ($PINNED_CDHASH) != signed helper ($FINAL_CDHASH)"
say "Helper $FINAL_CDHASH pinned (team $APP_TEAM)"
for b in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/InsomniaHelper"; do
    stamped=$(vtool -show-build "$b" | awk '$1 == "sdk" {print $2; exit}')
    [[ "$stamped" == "$SDK_VERSION" ]] || die "$(basename "$b") is stamped sdk $stamped, not $SDK_VERSION"
done
# One version everywhere: --version (HelperInfo.version) must match the bundle's CFBundleShortVersionString.
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$("$APP/Contents/MacOS/$APP_NAME" --version)" == "Insomnia $BUNDLE_VERSION" ]] \
    || die "HelperInfo.version ($("$APP/Contents/MacOS/$APP_NAME" --version)) != CFBundleShortVersionString ($BUNDLE_VERSION)"

# 10. Swap into place: old bundle aside, new one in, old one deleted ----------------------------------------------------
if [[ -e "$OUT" ]]; then
    OLD="$ROOT/build/.old.$$.app"
    mv "$OUT" "$OLD"
    mv "$APP" "$OUT"
    rm -rf "$OLD"
else
    mv "$APP" "$OUT"
fi
say "Built $OUT"
