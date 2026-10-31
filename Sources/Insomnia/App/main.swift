import AppKit
import Foundation
import InsomniaShared

// Entry point (ARCHITECTURE.md "App/main.swift").

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.filter { !$0.hasPrefix("-psn_") }   // old LaunchServices process serial number

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

#if DEBUG
let snapshotUsage = ["  Insomnia --snapshot <dir>            Render the panel, menu bar glyphs and icons to PNGs"]
#else
let snapshotUsage: [String] = []
#endif

let usage = ([
    "Insomnia \(HelperInfo.version): keeps your Mac awake. A pair of eyes in your menu bar.",
    "",
    "Usage:",
    "  Insomnia --gui                       Start the app (normally launched by Finder / LaunchServices)",
    "  Insomnia --export-icon <dir>         Write AppIcon.iconset PNGs into <dir> (used by scripts/build.sh)",
] + snapshotUsage + [
    "  Insomnia --helper-status             Exit 0 if the lid-mode helper is registered, 1 if not",
    "  Insomnia --unregister-helper         Remove the lid-mode helper registration",
    "  Insomnia --version",
    "",
    "Command line: run \"Insomnia help\", or \"insomnia help\" once installed from Settings ▸ Automations.",
]).joined(separator: "\n")

// Headless commands never create an NSApplication run loop. Only argv[1] decides (LaunchCommand).
switch LaunchCommand.parse(arguments, isCLICommand: { arg in MainActor.assumeIsolated { CLI.isCommand(arg) } }) {
case .app:
    if getppid() != 1 {
        // Typed in a terminal without arguments: print help rather than starting a second GUI by accident.
        // Through the ~/.local/bin/insomnia symlink that's the CLI's help; as the app binary, the app's.
        let invokedAsCLI = (arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "insomnia"
        printErr(invokedAsCLI ? MainActor.assumeIsolated { CLI.usage } : usage)
        exit(2)
    }
case .gui:
    break
case .version:
    print("Insomnia \(HelperInfo.version)")
    exit(0)
case .exportIcon(let dir):
    guard let dir else { printErr("--export-icon needs a directory"); exit(2) }
    let ok = MainActor.assumeIsolated { EyesRenderer.exportIconset(to: URL(fileURLWithPath: dir, isDirectory: true)) }
    exit(ok ? 0 : 1)
case .snapshot(let dir):
    #if DEBUG
    // Visual snapshots for review (debug builds only; never touches power management).
    guard let dir else { printErr("--snapshot needs a directory"); exit(2) }
    let ok = MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: dir, isDirectory: true)) }
    exit(ok ? 0 : 1)
    #else
    _ = dir
    printErr("--snapshot is only in debug builds (make snapshot)")
    exit(2)
    #endif
case .helperStatus:
    exit(MainActor.assumeIsolated { HelperCommands.status() })
case .unregisterHelper:
    exit(MainActor.assumeIsolated { HelperCommands.unregister() })
case .cli(let args):
    exit(MainActor.assumeIsolated { CLI.main(args) })
case .usage:
    printErr(usage)
    exit(2)
}

// 4. The app (LaunchServices or --gui).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
