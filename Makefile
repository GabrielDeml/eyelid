# Insomnia (ARCHITECTURE.md "Build model"). `make` builds; `make install` is the only target that uses sudo.
APP      := build/Insomnia.app
DEST     := /Applications/Insomnia.app
SNAPDIR  := build/snapshots

.PHONY: all app run snapshot install uninstall clean lid-verify

all: app

app:
	@scripts/build.sh

run: app
	@open "$(APP)"

# Renders the panel (light + dark), menu bar glyphs and icons to PNGs. Touches no power settings. The renderer is
# compiled into debug builds only.
snapshot:
	@swift build
	@"$$(swift build --show-bin-path)/Insomnia" --snapshot "$(SNAPDIR)"

# Lid mode needs a root-owned copy in /Applications (CLOSED_LID.md §2.3). Requires a signed build.
# Staged in a private directory that root creates (0700, unpredictable name, same volume), so nothing else can swap
# files between the copy and the rename. The STAGED, root-owned copy is what gets verified (signatures, requirements,
# the pinned helper cdhash, RunAtLoad, ownership) before it replaces the old one.
install: app
	@codesign -dvvv "$(APP)" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]' || \
		{ echo "make install needs a signed build (not INSOMNIA_SIGN_IDENTITY=-)"; exit 1; }
	@set -e; \
	T=$$(sudo mktemp -d /Applications/.insomnia.XXXXXX); sudo chmod 0755 "$$T"; \
	trap 'sudo rm -rf "$$T"' EXIT; \
	sudo ditto "$(APP)" "$$T/Insomnia.app"; \
	sudo chown -R root:wheel "$$T/Insomnia.app"; \
	sudo chmod -R go-w "$$T/Insomnia.app"; \
	scripts/lid-verify.sh --staged "$$T/Insomnia.app" || { echo "the staged copy failed verification; nothing installed"; exit 1; }; \
	q=0; scripts/quit-running.sh || q=$$?; \
	if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing installed"; exit 1; fi; \
	if [ -e "$(DEST)" ]; then sudo mv "$(DEST)" "$$T/previous.app"; fi; \
	sudo mv "$$T/Insomnia.app" "$(DEST)"; \
	if [ $$q -eq 3 ]; then open "$(DEST)"; echo "Installed $(DEST) and reopened it. Lid mode is set up from this copy only."; \
	else echo "Installed $(DEST). Open it from /Applications; lid mode is set up from this copy only."; fi

# Read-only lid-mode checks (CLOSED_LID.md §8): signatures, pinned helper, install location, registration, flag.
# `make lid-verify APP_TO_VERIFY=build/Insomnia.app` checks the build instead of the installed copy. Never uses sudo.
lid-verify:
	@scripts/lid-verify.sh $(if $(APP_TO_VERIFY),$(APP_TO_VERIFY),$(DEST))

# CLOSED_LID.md §9, in this order: quit every running copy (its Release runs while the safety nets still exist; abort
# if it won't quit), unregister the signed helper, reset SleepDisabled if our lid marker says the flag may still be
# ours (never a foreign flag), and only after a verified 0 delete the marker and remove the sudoers fallback's files.
uninstall:
	@q=0; scripts/quit-running.sh || q=$$?; if [ $$q -ne 0 ] && [ $$q -ne 3 ]; then echo "nothing removed"; exit 1; fi
	@if [ -x "$(DEST)/Contents/MacOS/Insomnia" ]; then "$(DEST)/Contents/MacOS/Insomnia" --unregister-helper; fi
	@M="$$HOME/Library/Application Support/Insomnia/lid-engaged"; \
	flag0() { /usr/sbin/ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = No'; }; \
	if [ -e "$$M" ]; then \
		flag0 || { echo "Lid mode may still hold SleepDisabled; resetting it"; sudo /usr/bin/pmset -a disablesleep 0; }; \
		flag0 || { echo "SleepDisabled is still set; nothing removed. Run: sudo pmset -a disablesleep 0"; exit 1; }; \
		rm -f "$$M"; \
	fi
	@if [ -e /etc/sudoers.d/zz_insomnia ] || [ -e /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist ]; then \
		sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true; \
		sudo /bin/sh -c 'rm -f /etc/sudoers.d/zz_insomnia /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist \
			/etc/sudoers.d/.insomnia.* /Library/LaunchDaemons/.insomnia.* /var/run/com.gdeml.insomnia.booted; \
			rm -rf /private/var/root/insomnia.*'; \
	fi
	sudo rm -rf "$(DEST)"

clean:
	rm -rf build .build
