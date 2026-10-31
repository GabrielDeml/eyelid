# Insomnia design docs

Read them in this order. If code and docs disagree, fix the docs first, then the code.

| Doc | Owns |
|---|---|
| [PRODUCT.md](PRODUCT.md) | Principles, users, v1 / Later / non-goals, voice and humour rules (quip budget, epic moments), naming |
| [UX.md](UX.md) | Every surface (menu bar, panel, Dock, Settings), lid sublabels, state × UI matrix (headline source of truth), notifications, copy deck, accessibility |
| [CLOSED_LID.md](CLOSED_LID.md) | Lid mode: sudoers rule, safety daemon, install/uninstall scripts, watchdog, guards, latch, `LidStatus` machine, M2 release blockers |
| [../ARCHITECTURE.md](../ARCHITECTURE.md) | Module contracts, the holds → guards → status engine, CLI/URL, build order, decisions log |
| `Sources/Insomnia/Core/Models.swift`, `Settings.swift` | The shared Swift contracts (states, guards, settings keys and defaults) the docs refer to |
