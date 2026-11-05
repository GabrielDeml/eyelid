import AppKit
import Foundation
import InsomniaShared

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.filter { !$0.hasPrefix("-psn_") }   // old LaunchServices process serial number

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
    Insomnia \(HelperInfo.version): keeps your Mac awake. A wide-awake moon in your menu bar.

    Usage (the app is normally opened from Finder):
      Insomnia --gui                  Start the app from a terminal
      Insomnia --version
      Insomnia --helper-status        Exit 0 if the lid-mode helper is registered, 1 if not
      Insomnia --unregister-helper    Remove the lid-mode helper registration (make uninstall)
      Insomnia --export-icon <dir>    Write AppIcon.iconset PNGs (scripts/build.sh)
      Insomnia --snapshot <dir>       Render the panel and menu bar glyphs to PNGs (debug builds)
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
    printErr("--snapshot is only in debug builds (make snapshot)")
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
