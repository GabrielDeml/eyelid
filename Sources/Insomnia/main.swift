import AppKit
import Foundation
import InsomniaShared

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.filter { !$0.hasPrefix("-psn_") }   // old LaunchServices process serial number

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
    Insomnia \(HelperInfo.version)
    Keeps your Mac awake from the menu bar. Normally you open it from Finder.

    Usage:
      Insomnia --gui                  Start the app from a terminal
      Insomnia --version              Print the version
      Insomnia --helper-status        Print the lid helper's status; exit 0 if registered, 1 if not
      Insomnia --unregister-helper    Quit Insomnia and unregister the lid helper (used when uninstalling)
      Insomnia --export-icon <dir>    Write AppIcon.iconset PNGs (used by scripts/build.sh)
      Insomnia --snapshot <dir>       Render the panel, Settings and menu bar icons to PNGs (debug builds only)
    """

let command = arguments.count > 1 ? arguments[1] : nil
let operand = arguments.count > 2 ? arguments[2] : nil
switch command {
case nil:
    // Typed in a terminal without arguments: print help rather than starting a second GUI by accident.
    if getppid() != 1 {
        printErr(usage)
        exit(2)
    }
case "--gui":
    break
case "--version":
    print("Insomnia \(HelperInfo.version)")
    exit(0)
case "--helper-status":
    exit(MainActor.assumeIsolated { HelperCommands.status() })
case "--unregister-helper":
    exit(MainActor.assumeIsolated { HelperCommands.unregister() })
case "--export-icon":
    guard let operand else { printErr("--export-icon needs a directory"); exit(2) }
    exit(MainActor.assumeIsolated { AppIcon.exportIconset(to: URL(fileURLWithPath: operand, isDirectory: true)) } ? 0 : 1)
case "--snapshot":
    #if DEBUG
    guard let operand else { printErr("--snapshot needs a directory"); exit(2) }
    exit(MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: operand, isDirectory: true)) } ? 0 : 1)
    #else
    printErr("--snapshot only works in debug builds. Use make snapshot.")
    exit(2)
    #endif
default:
    printErr(usage)
    exit(2)
}

MainActor.assumeIsolated {
    let app = InsomniaApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
