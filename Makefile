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
	if [ -e "$(DEST)" ]; then sudo mv "$(DEST)" "$$T/previous.app"; fi; \
	sudo mv "$$T/Insomnia.app" "$(DEST)"; \
	echo "Installed $(DEST). Open it from /Applications; lid mode is set up from this copy only."

# Read-only lid-mode checks (CLOSED_LID.md §8): signatures, pinned helper, install location, registration, flag.
# `make lid-verify APP_TO_VERIFY=build/Insomnia.app` checks the build instead of the installed copy. Never uses sudo.
lid-verify:
	@scripts/lid-verify.sh $(if $(APP_TO_VERIFY),$(APP_TO_VERIFY),$(DEST))

# Signed builds: unregister the helper. Leftovers of an unsigned (sudoers) setup are removed too (CLOSED_LID.md §9).
uninstall:
	@if [ -x "$(DEST)/Contents/MacOS/Insomnia" ]; then "$(DEST)/Contents/MacOS/Insomnia" --unregister-helper; fi
	@if [ -e /etc/sudoers.d/zz_insomnia ] || [ -e /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist ]; then \
		sudo launchctl bootout system/com.gdeml.insomnia.safety 2>/dev/null || true; \
		sudo rm -f /etc/sudoers.d/zz_insomnia /Library/LaunchDaemons/com.gdeml.insomnia.safety.plist; \
		rm -f "$$HOME/Library/Application Support/Insomnia/lid-engaged"; \
	fi
	sudo rm -rf "$(DEST)"

clean:
	rm -rf build .build
