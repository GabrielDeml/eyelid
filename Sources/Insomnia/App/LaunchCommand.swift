import Foundation

/// What the process was launched to do, decided from argv[1] only (main.swift). A flag anywhere later belongs to the
/// command that owns it: `insomnia run -- tool --snapshot out` must run `tool`, not render snapshots.
enum LaunchCommand: Equatable {
    /// No arguments: LaunchServices (or `--gui`) starts the app; from a terminal, help is printed instead.
    case app
    case gui
    case version
    /// `--export-icon <dir>` (scripts/build.sh); nil when the directory is missing.
    case exportIcon(String?)
    /// `--snapshot <dir>` (debug builds only); nil when the directory is missing.
    case snapshot(String?)
    case helperStatus
    case unregisterHelper
    /// `insomnia <command> …`: the CLI, with everything after argv[0].
    case cli([String])
    case usage

    /// `arguments` is argv with the old `-psn_` LaunchServices argument already removed.
    static func parse(_ arguments: [String], isCLICommand: (String) -> Bool) -> LaunchCommand {
        guard arguments.count > 1 else { return .app }
        let command = arguments[1]
        let next = arguments.count > 2 ? arguments[2] : nil
        switch command {
        case "--gui": return .gui
        case "--version": return .version
        case "--export-icon": return .exportIcon(next)
        case "--snapshot": return .snapshot(next)
        case "--helper-status": return .helperStatus
        case "--unregister-helper": return .unregisterHelper
        case _ where isCLICommand(command): return .cli(Array(arguments.dropFirst()))
        default: return .usage
        }
    }
}
