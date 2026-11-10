# Insomnia. See docs/DESIGN.md. `make` only builds; `make install` and `make uninstall` use sudo.
APP      := build/Insomnia.app
DEST     := /Applications/Insomnia.app
SNAPDIR  := build/snapshots

.PHONY: all app run snapshot test install uninstall clean lid-verify

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
	@"$$(swift build --show-bin-path)/Insomnia" --snapshot "$(SNAPDIR)"

# v1's ad-hoc setup left a passwordless sudoers rule for `pmset -a disablesleep 0|1` and a root safety daemon
# (docs/DESIGN.md "Security", v1 leftovers). install and uninstall remove both, after the running app has quit.
LEGACY_SUDOERS := /etc/sudoers.d/zz_insomnia
LEGACY_DAEMON  := /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist
REMOVE_LEGACY   = if [ -e $(LEGACY_SUDOERS) ] || [ -e $(LEGACY_DAEMON) ]; then \
	echo "Removing the old version's passwordless pmset rule and safety daemon"; \
	sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true; \
	sudo /bin/sh -c 'rm -f $(LEGACY_SUDOERS) $(LEGACY_DAEMON) /etc/sudoers.d/.insomnia.* \
		/Library/LaunchDaemons/.insomnia.* /var/run/com.gdeml.insomnia.booted; rm -rf /private/var/root/insomnia.*'; \
	if ! /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = No' \
		&& [ ! -e /var/run/com.gdeml.Insomnia.helper.engaged ]; then \
		echo "Your Mac still can't sleep (SleepDisabled is set, not by the lid helper). If no other app should be holding it, run: sudo pmset -a disablesleep 0"; \
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
	T=$$(sudo mktemp -d /Applications/.insomnia.XXXXXX); sudo chmod 0755 "$$T"; \
	trap 'sudo rm -rf "$$T"' EXIT; \
	sudo ditto --noacl "$(APP)" "$$T/Insomnia.app"; \
	sudo chown -R root:wheel "$$T/Insomnia.app"; \
	sudo chmod -RN "$$T/Insomnia.app"; \
	sudo chmod -R go-w "$$T/Insomnia.app"; \
	scripts/lid-verify.sh --staged "$$T/Insomnia.app" || { echo "the staged copy failed verification; nothing installed"; exit 1; }; \
	q=0; scripts/quit-running.sh || q=$$?; \
	if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing installed"; exit 1; fi; \
	$(REMOVE_LEGACY); \
	if [ -e "$(DEST)" ]; then sudo mv "$(DEST)" "$$T/previous.app"; fi; \
	sudo mv "$$T/Insomnia.app" "$(DEST)"; \
	if sudo launchctl print system/com.gdeml.Insomnia.helper >/dev/null 2>&1; then \
		sudo launchctl kickstart -k system/com.gdeml.Insomnia.helper || echo "Warning: couldn't restart the lid helper. If lid mode fails, run: sudo launchctl kickstart -k system/com.gdeml.Insomnia.helper"; \
	fi; \
	if [ $$q -eq 3 ]; then open "$(DEST)"; echo "Installed $(DEST) and reopened it. Lid mode works only from this copy."; \
	else echo "Installed $(DEST). Open it from Applications. Lid mode works only from this copy."; fi

# Read-only lid-mode checks: signatures, pinned helper, install location, registration, flag.
# `make lid-verify APP_TO_VERIFY=build/Insomnia.app` checks the build instead of the installed copy. Never uses sudo.
lid-verify:
	@scripts/lid-verify.sh $(if $(APP_TO_VERIFY),$(APP_TO_VERIFY),$(DEST))

# Quit every running copy (its quit releases lid mode while the helper still exists; abort if it won't quit),
# unregister the helper (it resets a flag it owns when stopped), check SleepDisabled is back to 0, then delete the app.
uninstall:
	@q=0; scripts/quit-running.sh || q=$$?; if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing removed"; exit 1; fi
	@if [ -x "$(DEST)/Contents/MacOS/Insomnia" ]; then "$(DEST)/Contents/MacOS/Insomnia" --unregister-helper; fi
	@$(REMOVE_LEGACY)
	@if ! /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = No'; then \
		echo "Your Mac still can't sleep (SleepDisabled is set). If no other app should be holding it, run: sudo pmset -a disablesleep 0"; fi
	@rm -f "$$HOME/Library/Application Support/Insomnia/lid-engaged" "$$HOME/Library/Application Support/Insomnia/control.sock"
	sudo rm -rf "$(DEST)"

clean:
	rm -rf build .build
