#!/bin/bash
# Build the installer package for GitHub Releases: dist/Insomnia-<version>.pkg and dist/SHA256SUMS.txt
# (docs/RELEASE.md "Building a release"). dist/ only ever holds the last run's output.
#
#   scripts/release.sh                 sign, notarize, staple, verify → dist/Insomnia-<version>.pkg
#   scripts/release.sh --no-notarize   Developer ID signed, not notarized → dist/Insomnia-<version>-unnotarized.pkg
#   scripts/release.sh --dev           Apple Development app, unsigned pkg → dist/Insomnia-<version>-dev.pkg (test Macs)
#
# Environment: INSOMNIA_SIGN_IDENTITY, INSOMNIA_INSTALLER_IDENTITY, INSOMNIA_SIGN_KEYCHAIN, NOTARY_PROFILE or
# NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER, RELEASE_TAG. Every step is a hard gate. Never installs anything, never
# needs sudo.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP_NAME=Insomnia
BUNDLE_ID=com.gdeml.Insomnia
PKG_ID=com.gdeml.Insomnia.pkg
HELPER_PLIST=Contents/Library/LaunchDaemons/com.gdeml.Insomnia.helper.plist
APP="$ROOT/build/$APP_NAME.app"
WORK="$ROOT/build/pkg"
DIST="$ROOT/dist"
COMPONENT=Insomnia-component.pkg
TEMPLATE="$ROOT/pkg/Distribution.xml.in"
PKG_SCRIPTS=("$ROOT/pkg/scripts/preinstall" "$ROOT/pkg/scripts/postinstall" "$ROOT/scripts/quit-running.sh")

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,11s/^# \{0,1\}//p' "$0"; }
xp() { xmllint --xpath "$1" "$2" 2>/dev/null || true; }   # one XPath value from an XML file, empty if none

MODE=release
case "${1:-}" in
    "") ;;
    --no-notarize) MODE=no-notarize ;;
    --dev) MODE=dev ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option '$1'" ;;
esac
(( $# <= 1 )) || die "pass at most one option"
SIGNED=1 SUFFIX=""   # only a notarized package gets the plain name
case "$MODE" in dev) SIGNED=0 SUFFIX=-dev ;; no-notarize) SUFFIX=-unnotarized ;; esac
KEYCHAIN="${INSOMNIA_SIGN_KEYCHAIN:-}"

# Locks the signing keychain again if we unlocked it for productbuild. build.sh locks it after its own use.
KEYCHAIN_UNLOCKED=0
on_exit() { if (( KEYCHAIN_UNLOCKED )); then security lock-keychain "$KEYCHAIN" || true; fi; }
trap on_exit EXIT

# 1. Version and preconditions, all checked before the slow build ------------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "CFBundleShortVersionString '$VERSION' isn't a plain dotted version"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$VERSION" ]]; then
    die "RELEASE_TAG is '$RELEASE_TAG' but Resources/Info.plist says $VERSION: the tag must be v$VERSION"
fi
PKG_NAME="$APP_NAME-$VERSION$SUFFIX.pkg"
say "Insomnia $VERSION, mode: $MODE"

problems=()
for tool in swift pkgbuild productbuild pkgutil lsbom xmllint shasum lipo codesign; do
    command -v "$tool" >/dev/null || problems+=("missing tool: $tool")
done
[[ -f "$TEMPLATE" ]] || problems+=("missing ${TEMPLATE#"$ROOT"/}")
for s in "${PKG_SCRIPTS[@]}"; do [[ -f "$s" ]] || problems+=("missing ${s#"$ROOT"/}"); done

INSTALLER_ID=""
if (( SIGNED )); then
    WHERE="security find-identity -v${KEYCHAIN:+ $KEYCHAIN}"
    # The app identity, as build.sh will pick it in release mode (it checks again, but only after these checks pass).
    CODESIGN_IDS=$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} 2>/dev/null || true)
    APP_ID="${INSOMNIA_SIGN_IDENTITY:-}"
    if [[ -z "$APP_ID" ]]; then
        APP_ID=$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$CODESIGN_IDS")
        APP_ID=${APP_ID%%$'\n'*}
        [[ -n "$APP_ID" ]] || problems+=("no 'Developer ID Application' identity ($WHERE -p codesigning)")
    elif [[ "$APP_ID" != "Developer ID Application: "* ]]; then
        problems+=("INSOMNIA_SIGN_IDENTITY '$APP_ID' isn't a 'Developer ID Application' identity")
    elif ! grep -Fq -- "$APP_ID" <<<"$CODESIGN_IDS"; then
        problems+=("INSOMNIA_SIGN_IDENTITY '$APP_ID' not found ($WHERE -p codesigning)")
    fi
    # The installer identity: basic policy, since a Developer ID Installer certificate isn't a code-signing one.
    ALL_IDS=$(security find-identity -v ${KEYCHAIN:+"$KEYCHAIN"} 2>/dev/null || true)
    INSTALLER_ID="${INSOMNIA_INSTALLER_IDENTITY:-}"
    if [[ -z "$INSTALLER_ID" ]]; then
        INSTALLER_ID=$(sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' <<<"$ALL_IDS")
        INSTALLER_ID=${INSTALLER_ID%%$'\n'*}
        [[ -n "$INSTALLER_ID" ]] || problems+=("no 'Developer ID Installer' identity ($WHERE)")
    else
        # A name or a SHA-1 hash; either way its line must be a Developer ID Installer identity.
        line=$(grep -F -- "$INSTALLER_ID" <<<"$ALL_IDS" || true)
        not_installer="INSOMNIA_INSTALLER_IDENTITY '$INSTALLER_ID' isn't a 'Developer ID Installer' identity ($WHERE)"
        [[ "$line" == *'"Developer ID Installer: '* ]] || problems+=("$not_installer")
    fi
fi

NOTARY_AUTH=()
if [[ "$MODE" == release ]]; then
    for tool in notarytool stapler; do
        xcrun --find "$tool" >/dev/null 2>&1 || problems+=("missing tool: xcrun $tool")
    done
    command -v spctl >/dev/null || problems+=("missing tool: spctl")
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    elif [[ -n "${NOTARY_KEY:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER:-}" ]]; then
        missing=()
        for v in NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
        if (( ${#missing[@]} )); then
            problems+=("incomplete notary API key: ${missing[*]} not set")
        elif [[ ! -r "$NOTARY_KEY" ]]; then
            problems+=("NOTARY_KEY '$NOTARY_KEY' isn't a readable file")
        fi
        NOTARY_AUTH=(--key "${NOTARY_KEY:-}" --key-id "${NOTARY_KEY_ID:-}" --issuer "${NOTARY_ISSUER:-}")
    else
        problems+=("no notary credentials: set NOTARY_PROFILE (a notarytool store-credentials profile), or NOTARY_KEY,
       NOTARY_KEY_ID and NOTARY_ISSUER (an App Store Connect API key), or use --no-notarize")
    fi
fi

# A notarized package carries the plain release name, so it must come from committed code.
DIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null || echo "git status failed")
if [[ "$MODE" == release && -n "$DIRTY" ]]; then
    problems+=("uncommitted changes in the working tree (git status): release builds come from committed code")
fi

if (( ${#problems[@]} )); then
    printf '\033[31merror:\033[0m nothing was built (mode: %s):\n' "$MODE" >&2
    printf '  - %s\n' "${problems[@]}" >&2
    (( SIGNED )) && printf '  (--dev builds an unsigned package with the Apple Development identity)\n' >&2
    exit 1
fi
if (( SIGNED )); then say "App identity: $APP_ID"; say "Installer identity: $INSTALLER_ID"; fi

# Fresh work dir; nothing stale in dist/ can pass for this run's output.
rm -rf "$WORK"
mkdir -p "$WORK/scripts" "$DIST"
rm -f "$DIST/$APP_NAME"-*.pkg "$DIST/SHA256SUMS.txt"

# 2. Build the app -----------------------------------------------------------------------------------------------------
if (( SIGNED )); then
    INSOMNIA_RELEASE=1 "$ROOT/scripts/build.sh"
else
    env -u INSOMNIA_RELEASE "$ROOT/scripts/build.sh"
fi
[[ -d "$APP" ]] || die "build.sh didn't produce $APP"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "$VERSION" ]] || die "built app is version $BUILT_VERSION, not $VERSION"
for b in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/InsomniaHelper"; do
    [[ "$(lipo -archs "$b")" == arm64 ]] || die "$(basename "$b") isn't arm64 only ($(lipo -archs "$b"))"
done
APP_INFO=$(codesign -dvvv "$APP" 2>&1)
APP_TEAM=$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_INFO")
[[ -n "$APP_TEAM" && "$APP_TEAM" != "not set" ]] || die "the built app has no Team ID"
if (( SIGNED )); then
    for b in "$APP" "$APP/Contents/MacOS/InsomniaHelper"; do
        info=$(codesign -dvvv "$b" 2>&1)
        grep -q '^Authority=Developer ID Application: ' <<<"$info" || die "$(basename "$b") isn't Developer ID signed"
        grep -q '^Timestamp=' <<<"$info" || die "$(basename "$b") has no secure timestamp"
    done
else
    # build.sh signs with INSOMNIA_SIGN_IDENTITY when it is set; a dev package must not carry a Developer ID app.
    grep -q '^Authority=Apple Development: ' <<<"$APP_INFO" \
        || die "--dev expects an Apple Development signed app (unset INSOMNIA_SIGN_IDENTITY)"
fi

# 3. Installer scripts: ours and quit-running.sh, executable, nothing else ---------------------------------------------
say "Staging installer scripts"
for s in "${PKG_SCRIPTS[@]}"; do
    cp -X "$s" "$WORK/scripts/"
    chmod 755 "$WORK/scripts/$(basename "$s")"
done
[[ "$(ls -A "$WORK/scripts" | tr '\n' ' ')" == "postinstall preinstall quit-running.sh " ]] \
    || die "build/pkg/scripts holds more than the three installer scripts: $(ls -A "$WORK/scripts")"

# 4. Component package -------------------------------------------------------------------------------------------------
# From a copy without extended attributes: pkgbuild archives them (as ._ entries) and Installer puts them back on every
# user's Mac, and the build's are machine-local (com.apple.provenance, com.apple.macl). The signature doesn't cover
# them.
say "pkgbuild $COMPONENT"
STAGED_APP="$WORK/root/$APP_NAME.app"
mkdir -p "$WORK/root"
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGED_APP"
codesign --verify --strict --deep "$STAGED_APP" || die "the attribute-free copy of the app fails codesign --verify"
pkgbuild --component "$STAGED_APP" --install-location /Applications --identifier "$PKG_ID" --version "$VERSION" \
    --scripts "$WORK/scripts" --ownership recommended "$WORK/$COMPONENT"

# 5. Check the component package ---------------------------------------------------------------------------------------
say "Checking the component package"
EXP="$WORK/expanded"
pkgutil --expand "$WORK/$COMPONENT" "$EXP"
PI="$EXP/PackageInfo"
[[ "$(xp 'string(/pkg-info/@identifier)' "$PI")" == "$PKG_ID" ]] || die "PackageInfo identifier isn't $PKG_ID"
[[ "$(xp 'string(/pkg-info/@version)' "$PI")" == "$VERSION" ]] || die "PackageInfo version isn't $VERSION"
[[ "$(xp 'string(/pkg-info/@install-location)' "$PI")" == /Applications ]] \
    || die "PackageInfo install-location isn't /Applications"
# Installer must never "upgrade" a stray copy elsewhere (build/Insomnia.app): older pkgbuilds default to relocatable.
[[ "$(xp 'string(/pkg-info/@relocatable)' "$PI")" == false ]] || die "PackageInfo isn't relocatable=\"false\""
[[ "$(xp 'count(/pkg-info/relocate/*)' "$PI")" == 0 ]] || die "PackageInfo lists relocatable bundles"
[[ "$(xp 'string(/pkg-info/bundle[@path="./Insomnia.app"]/@id)' "$PI")" == "$BUNDLE_ID" ]] \
    || die "PackageInfo doesn't describe ./Insomnia.app as $BUNDLE_ID"
for el in strict-identifier upgrade-bundle; do
    [[ "$(xp "string(/pkg-info/$el/bundle/@id)" "$PI")" == "$BUNDLE_ID" ]] || die "PackageInfo $el isn't $BUNDLE_ID"
done
for s in preinstall postinstall; do
    [[ "$(xp "string(/pkg-info/scripts/$s/@file)" "$PI")" == "./$s" ]] || die "PackageInfo doesn't run ./$s"
done

# Payload: root:wheel and the build's modes on every item; the payload root "." (/Applications) carries no mode.
BOM=$(lsbom -p MUGf "$EXP/Bom")
bad=() appledouble=() root_seen=0
while IFS=$'\t' read -r mode user group path; do
    mode=${mode%% *}   # lsbom pads the mode column
    if [[ "$path" == . ]]; then
        root_seen=1
        [[ "$mode" =~ ^\?-+$ ]] || bad+=(". records mode '$mode' (it would reset /Applications)")
        continue
    fi
    [[ "$(basename "$path")" == ._* ]] && appledouble+=("$path")
    [[ "$path" == ./Insomnia.app || "$path" == ./Insomnia.app/* || "$path" == ./._Insomnia.app ]] \
        || bad+=("$path is outside Insomnia.app")
    [[ "$user:$group" == root:wheel ]] || bad+=("$path is $user:$group, not root:wheel")
    case "$mode" in
        drwxr-xr-x|-rwxr-xr-x|-rw-r--r--|lrwxr-xr-x) ;;
        *) bad+=("$path has mode $mode, not 755 or 644") ;;
    esac
done <<<"$BOM"
(( root_seen )) || bad+=("the payload has no root entry '.'")
BOM_PATHS=$(cut -f4 <<<"$BOM")
for p in Contents/MacOS/Insomnia Contents/MacOS/InsomniaHelper Contents/Info.plist "$HELPER_PLIST" \
         Contents/_CodeSignature/CodeResources; do
    grep -Fqx -- "./Insomnia.app/$p" <<<"$BOM_PATHS" || bad+=("the payload lacks ./Insomnia.app/$p")
done
if (( ${#bad[@]} )); then
    printf '\033[31merror:\033[0m the component package payload fails its checks:\n' >&2
    printf '  - %s\n' "${bad[@]}" >&2
    exit 1
fi
if (( ${#appledouble[@]} )); then
    # Attributes the kernel adds to every new file (com.apple.provenance, when the build runs under an app that macOS
    # tracks) survive the copy above. Fine on a test Mac, never in a release.
    attrs=$(xattr -r "$STAGED_APP" 2>/dev/null | sed 's/.*: //' | sort -u | tr '\n' ' ')
    msg="${#appledouble[@]} AppleDouble (._) payload entries; Installer would put these attributes on users'"
    msg+=" Macs: $attrs"
    if (( SIGNED )); then die "$msg. Build from Terminal or CI, not from an app macOS tracks."; fi
    warn "$msg"
fi

# Scripts archive: exactly the three staged scripts, executable and unchanged. AppleDouble entries are skipped here:
# they come from the same attributes as the payload's, which a signed build has already refused above.
for s in preinstall postinstall quit-running.sh; do
    f="$EXP/Scripts/$s"
    [[ -f "$f" && -x "$f" ]] || die "the Scripts archive lacks an executable $s"
    cmp -s "$f" "$WORK/scripts/$s" || die "$s in the Scripts archive differs from build/pkg/scripts/$s"
done
extra=$(cd "$EXP/Scripts" && find . -mindepth 1 ! -name '._*' ! -name preinstall ! -name postinstall \
    ! -name quit-running.sh)
[[ -z "$extra" ]] || die "the Scripts archive holds more than the three scripts: $extra"

# 6. Product archive ---------------------------------------------------------------------------------------------------
say "productbuild $PKG_NAME"
sed -e "s|__VERSION__|$VERSION|g" -e "s|__COMPONENT_PKG__|$COMPONENT|g" "$TEMPLATE" > "$WORK/Distribution.xml"
if grep -n '__[A-Z][A-Z0-9_]*__' "$WORK/Distribution.xml" >&2; then die "unfilled placeholders in Distribution.xml"; fi
xmllint --noout "$WORK/Distribution.xml" || die "build/pkg/Distribution.xml isn't well-formed XML"
PRODUCT="$WORK/unverified.pkg"   # renamed to $PKG_NAME only in step 9, after every check
PB=(productbuild --distribution "$WORK/Distribution.xml" --package-path "$WORK")
if (( SIGNED )); then
    PB+=(--sign "$INSTALLER_ID" --timestamp)
    if [[ -n "$KEYCHAIN" ]]; then
        say "Unlocking signing keychain $KEYCHAIN"
        security unlock-keychain "$KEYCHAIN"
        KEYCHAIN_UNLOCKED=1
        PB+=(--keychain "$KEYCHAIN")
    fi
fi
"${PB[@]}" "$PRODUCT"
if (( KEYCHAIN_UNLOCKED )); then security lock-keychain "$KEYCHAIN"; KEYCHAIN_UNLOCKED=0; fi

# 7. Notarize and staple -----------------------------------------------------------------------------------------------
if [[ "$MODE" == release ]]; then
    say "Notarizing (notarytool submit --wait, usually a few minutes)"
    rc=0
    xcrun notarytool submit "$PRODUCT" "${NOTARY_AUTH[@]}" --wait --timeout 1h --output-format json \
        > "$WORK/notary.json" || rc=$?
    SUBMISSION=$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || true)
    STATUS=$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || true)
    [[ -n "$SUBMISSION" ]] || die "notarytool submit failed (exit $rc) without a submission: $(cat "$WORK/notary.json")"
    say "Notary submission $SUBMISSION: ${STATUS:-no status} (notarytool exit $rc)"
    if xcrun notarytool log "$SUBMISSION" "${NOTARY_AUTH[@]}" "$WORK/notary-log.json"; then
        cat "$WORK/notary-log.json"; echo
    else
        warn "couldn't fetch the notary log for $SUBMISSION"
    fi
    [[ "$STATUS" == Accepted ]] || die "notarization status is '${STATUS:-none}', not Accepted (log above)"
    say "Stapling"
    xcrun stapler staple "$PRODUCT"
    xcrun stapler validate "$PRODUCT"
fi

# 8. Verify the product ------------------------------------------------------------------------------------------------
say "Verifying $PKG_NAME"
if (( SIGNED )); then
    SIG=$(pkgutil --check-signature "$PRODUCT") || die "pkgutil --check-signature failed: $SIG"
    printf '%s\n' "$SIG"
    grep -q 'Status: signed by a developer certificate issued by Apple' <<<"$SIG" \
        || die "the package signature isn't a trusted Developer ID one (see Status above)"
    grep -Eq "Developer ID Installer: .*\($APP_TEAM\)" <<<"$SIG" \
        || die "the package isn't signed with a Developer ID Installer identity of team $APP_TEAM"
    grep -q 'Signed with a trusted timestamp' <<<"$SIG" || die "the package signature has no trusted timestamp"
    if [[ "$MODE" == release ]]; then
        GK=$(spctl -a -vvv -t install "$PRODUCT" 2>&1) || die "Gatekeeper rejects the package: $GK"
        printf '%s\n' "$GK"
        grep -q 'source=Notarized Developer ID' <<<"$GK" || die "Gatekeeper doesn't see a notarized Developer ID pkg"
    else
        # Not notarized, so Gatekeeper is expected to reject it; shown for information only.
        spctl -a -vvv -t install "$PRODUCT" 2>&1 || true
    fi
fi
PEXP="$WORK/product"
pkgutil --expand "$PRODUCT" "$PEXP"
DIST_XML="$PEXP/Distribution"
[[ "$(xp 'string(/installer-gui-script/options/@hostArchitectures)' "$DIST_XML")" == arm64 ]] \
    || die "the product's Distribution doesn't say hostArchitectures=\"arm64\""
[[ "$(xp 'string(/installer-gui-script/domains/@enable_localSystem)' "$DIST_XML")" == true \
    && "$(xp 'string(/installer-gui-script/domains/@enable_anywhere)' "$DIST_XML")" == false \
    && "$(xp 'string(/installer-gui-script/domains/@enable_currentUserHome)' "$DIST_XML")" == false ]] \
    || die "the product's Distribution must allow only the local system domain"
[[ "$(xp "count(//pkg-ref[@id=\"$PKG_ID\"][@version=\"$VERSION\"])" "$DIST_XML")" == 1 ]] \
    || die "the product's Distribution doesn't reference $PKG_ID version $VERSION"
for f in PackageInfo Bom Payload; do
    cmp -s "$PEXP/$COMPONENT/$f" "$EXP/$f" \
        || die "the product's $COMPONENT/$f differs from the checked component package"
done
diff -rq "$PEXP/$COMPONENT/Scripts" "$EXP/Scripts" >/dev/null \
    || die "the product's $COMPONENT/Scripts differ from the checked component package"
[[ "$(xp 'count(/installer-gui-script/installation-check[@script="checkInstalledInsomnia()"])' "$DIST_XML")" == 1 ]] \
    || die "the product's Distribution lacks the installation check"

# 9. Publish to dist/, last --------------------------------------------------------------------------------------------
mv "$PRODUCT" "$DIST/$PKG_NAME"
(cd "$DIST" && shasum -a 256 "$PKG_NAME" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt >/dev/null)
[[ -z "$DIRTY" ]] || warn "built from a working tree with uncommitted changes"
say "Done ($MODE)"
printf '  %-10s %s\n' package "$DIST/$PKG_NAME" checksums "$DIST/SHA256SUMS.txt" sha256 \
    "$(cut -d' ' -f1 "$DIST/SHA256SUMS.txt")" commit "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
case "$MODE" in
    release) echo "  Signed, notarized and stapled." ;;
    no-notarize) echo "  Signed but NOT notarized: for local trials only, don't publish it." ;;
    dev) echo "  Unsigned package with an Apple Development app: for test machines only, don't publish it." ;;
esac
