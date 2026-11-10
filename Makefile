# Eyelid. See docs/DESIGN.md and docs/RELEASE.md. `make` only builds; `make install` and `make uninstall` use sudo.
APP      := build/Eyelid.app
DEST     := /Applications/Eyelid.app
SNAPDIR  := build/snapshots

.PHONY: all app run snapshot test install uninstall clean lid-verify release pkg-dev

all: app

app:
	@scripts/build.sh

run: app
	@open "$(APP)"

test:
	@swift test

# Renders the panel (light + dark), menu bar glyphs and icons to PNGs. Touches no power settings. The renderer is
# compiled into debug builds only.
snapshot:
	@swift build
	@"$$(swift build --show-bin-path)/Eyelid" --snapshot "$(SNAPDIR)"

# v1's ad-hoc setup left a passwordless sudoers rule for `pmset -a disablesleep 0|1` and a root safety daemon
# (docs/DESIGN.md "Security", v1 leftovers). install and uninstall remove both after QUIT_OLD, so a v1 app holding the
# flag through the rule has released it.
LEGACY_SUDOERS := /etc/sudoers.d/zz_insomnia
LEGACY_DAEMON  := /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist
REMOVE_LEGACY   = if [ -e $(LEGACY_SUDOERS) ] || [ -e $(LEGACY_DAEMON) ]; then \
	echo "Removing the old version's passwordless pmset rule and safety daemon"; \
	sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true; \
	sudo /bin/sh -c 'rm -f $(LEGACY_SUDOERS) $(LEGACY_DAEMON) /etc/sudoers.d/.insomnia.* \
		/Library/LaunchDaemons/.insomnia.* /var/run/com.gdeml.insomnia.booted; rm -rf /private/var/root/insomnia.*'; \
	if ! /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = No' \
		&& [ ! -e /var/run/com.gdeml.Eyelid.helper.engaged ]; then \
		echo "Your Mac still can't sleep (SleepDisabled is set, not by the lid helper). If no other app should be holding it, run: sudo pmset -a disablesleep 0"; \
	fi; \
fi

# Quits every running copy of the old app (bundle ID com.gdeml.Insomnia: v1 or a pre-rename build), wherever it runs.
# v1's ad-hoc builds never ran from /Applications, so nothing below would quit them. Its bundle-ID check leaves any
# other app named Insomnia alone. Exit 3 means it was running and has quit.
QUIT_OLD = scripts/quit-running.sh --insomnia || [ $$? -eq 3 ]

# Builds from before the rename were called Insomnia: /Applications/Insomnia.app, bundle ID com.gdeml.Insomnia, helper
# com.gdeml.Insomnia.helper (docs/DESIGN.md "Security", pre-rename builds). Only a copy with exactly that bundle ID is
# touched: any other app named Insomnia is someone else's. QUIT_OLD has already quit it (its quit releases lid mode);
# its own --unregister-helper unregisters its helper, which resets a flag it owns when stopped. If that fails the old
# copy stays and the caller stops, so no old helper is left registered to a deleted bundle. Runs before REMOVE_LEGACY,
# whose SleepDisabled hint only knows the new helper's ownership file. Settings aren't migrated: the defaults domain is
# new.
PRERENAME_APP := /Applications/Insomnia.app
PRERENAME_ID  := com.gdeml.Insomnia
PRERENAME_SUPPORT = $$HOME/Library/Application Support/Insomnia
REMOVE_PRERENAME = if [ -d $(PRERENAME_APP) ] && [ "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
		$(PRERENAME_APP)/Contents/Info.plist 2>/dev/null)" = $(PRERENAME_ID) ]; then \
	echo "Removing $(PRERENAME_APP), a build from before the rename to Eyelid"; \
	if [ -x $(PRERENAME_APP)/Contents/MacOS/Insomnia ] \
		&& ! $(PRERENAME_APP)/Contents/MacOS/Insomnia --unregister-helper; then \
		echo "Couldn't unregister the old Insomnia's lid helper, so $(PRERENAME_APP) was left in place."; false; \
	else \
		sudo rm -rf $(PRERENAME_APP); \
		rm -f "$(PRERENAME_SUPPORT)/lid-engaged" "$(PRERENAME_SUPPORT)/control.sock"; \
	fi; \
fi

# Lid mode needs a root-owned copy in /Applications: launchd runs the helper as root straight out of the bundle.
# Staged in a directory root creates (unpredictable name, same volume; 0755 so the unprivileged lid-verify can read
# it). Only root can add, remove or replace anything inside it; its own name in the admin-writable /Applications can
# be renamed, which gains nothing, because only a root-owned bundle passes the app's and helper's run-time checks. Copied
# without ACLs (--noacl, then chmod -RN): an ACL would leave a root-owned 0755 file writable. The STAGED, root-owned
# copy is what gets verified (signatures, requirements, the pinned helper cdhash, RunAtLoad, ownership, no ACLs)
# before it replaces the old one. The helper then pins this exact app (docs/DESIGN.md "Security").
install: app
	@codesign -dvvv "$(APP)" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]' || \
		{ echo "make install needs a signed build"; exit 1; }
	@set -e; \
	T=$$(sudo mktemp -d /Applications/.eyelid.XXXXXX); sudo chmod 0755 "$$T"; \
	trap 'sudo rm -rf "$$T"' EXIT; \
	sudo ditto --noacl "$(APP)" "$$T/Eyelid.app"; \
	sudo chown -R root:wheel "$$T/Eyelid.app"; \
	sudo chmod -RN "$$T/Eyelid.app"; \
	sudo chmod -R go-w "$$T/Eyelid.app"; \
	scripts/lid-verify.sh --staged "$$T/Eyelid.app" || { echo "the staged copy failed verification; nothing installed"; exit 1; }; \
	q=0; scripts/quit-running.sh || q=$$?; \
	if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing installed"; exit 1; fi; \
	$(QUIT_OLD) || { echo "nothing installed"; exit 1; }; \
	$(REMOVE_PRERENAME) || { echo "nothing installed"; exit 1; }; \
	$(REMOVE_LEGACY); \
	if [ -e "$(DEST)" ]; then sudo mv "$(DEST)" "$$T/previous.app"; fi; \
	sudo mv "$$T/Eyelid.app" "$(DEST)"; \
	if sudo launchctl print system/com.gdeml.Eyelid.helper >/dev/null 2>&1; then \
		sudo launchctl kickstart -k system/com.gdeml.Eyelid.helper || echo "Warning: couldn't restart the lid helper. If lid mode fails, run: sudo launchctl kickstart -k system/com.gdeml.Eyelid.helper"; \
	fi; \
	if [ $$q -eq 3 ]; then open "$(DEST)"; echo "Installed $(DEST) and reopened it. Lid mode works only from this copy."; \
	else echo "Installed $(DEST). Open it from Applications. Lid mode works only from this copy."; fi

# Read-only lid-mode checks: signatures, pinned helper, install location, registration, flag.
# `make lid-verify APP_TO_VERIFY=build/Eyelid.app` checks the build instead of the installed copy. Never uses sudo.
lid-verify:
	@scripts/lid-verify.sh $(if $(APP_TO_VERIFY),$(APP_TO_VERIFY),$(DEST))

# Quit every running copy, Eyelid's and the old Insomnia's (its quit releases lid mode while the helper still exists;
# abort if it won't quit), remove a pre-rename Insomnia build, unregister the helper (it resets a flag it owns when
# stopped), remove v1's leftovers, check SleepDisabled is back to 0, then delete the app and forget the installer
# receipt, if the pkg installed it.
uninstall:
	@q=0; scripts/quit-running.sh || q=$$?; if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing removed"; exit 1; fi
	@$(QUIT_OLD) || { echo "nothing removed"; exit 1; }
	@$(REMOVE_PRERENAME) || { echo "nothing removed"; exit 1; }
	@if [ -x "$(DEST)/Contents/MacOS/Eyelid" ]; then "$(DEST)/Contents/MacOS/Eyelid" --unregister-helper; fi
	@$(REMOVE_LEGACY)
	@if ! /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = No'; then \
		echo "Your Mac still can't sleep (SleepDisabled is set). If no other app should be holding it, run: sudo pmset -a disablesleep 0"; fi
	@rm -f "$(PRERENAME_SUPPORT)/lid-engaged" "$(PRERENAME_SUPPORT)/control.sock"
	sudo rm -rf "$(DEST)"
	@if pkgutil --pkg-info com.gdeml.Eyelid.pkg >/dev/null 2>&1; then sudo pkgutil --forget com.gdeml.Eyelid.pkg; fi

# The installer package for GitHub Releases (docs/RELEASE.md), written to dist/. Never installs anything.
# `make release`: Developer ID signed, notarized and stapled. `make pkg-dev`: Apple Development build, unsigned pkg.
release:
	@scripts/release.sh

pkg-dev:
	@scripts/release.sh --dev

clean:
	rm -rf build .build
