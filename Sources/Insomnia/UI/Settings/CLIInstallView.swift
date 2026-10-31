import AppKit
import Darwin
import InsomniaShared
import Observation
import SwiftUI

// MARK: - Settings ▸ Automations ▸ "Command line" (UX.md §4.2, ARCHITECTURE.md "Automations tab")
//
//   insomnia   ● Installed at ~/.local/bin/insomnia                    [Reinstall] [Remove]
//              ⚠ ~/.local/bin is not on your PATH. Add: export PATH="$HOME/.local/bin:$PATH"  [Copy]
//
// The install is one symlink, ~/.local/bin/insomnia → this app's own executable. No sudo, no /usr/local, nothing
// outside the home folder. A file there that isn't ours is never replaced or removed.

/// The symlink logic, kept free of UI so it can be tested against a temporary folder.
struct CLIInstaller: Sendable {
    enum State: Equatable, Sendable {
        case notInstalled
        /// The link points at this copy of Insomnia.
        case installed
        /// An Insomnia link that points at another copy (an old build, a deleted folder). Reinstall fixes it.
        case pointsElsewhere(String)
        /// Something else is at the path (a file, or a link to another program). Left alone.
        case occupied
    }

    enum Failure: Error, Equatable, Sendable {
        case occupied
        case noExecutable
        case system(String)

        var message: String {
            switch self {
            case .occupied: return "Something else is already at ~/.local/bin/insomnia. Rename it, then try again."
            case .noExecutable: return "Couldn't find Insomnia's own executable."
            case .system(let detail): return detail
            }
        }
    }

    /// ~/.local/bin/insomnia
    let link: URL
    /// The app's executable, symlinks resolved.
    let target: URL?

    static var standard: CLIInstaller {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return CLIInstaller(link: home.appendingPathComponent(".local/bin/insomnia"),
                            target: Bundle.main.executableURL?.resolvingSymlinksInPath())
    }

    var directory: URL { link.deletingLastPathComponent() }

    /// "~/.local/bin/insomnia"
    var displayPath: String { Self.abbreviate(link.path) }
    var displayDirectory: String { Self.abbreviate(directory.path) }

    static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#

    func state() -> State {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: link.path) else { return .notInstalled }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return .occupied }
        let resolved = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
        if let target, resolved.resolvingSymlinksInPath().path == target.path { return .installed }
        return Self.looksLikeInsomnia(resolved.path) ? .pointsElsewhere(Self.abbreviate(resolved.path)) : .occupied
    }

    /// Creates or replaces our link atomically (a temporary link renamed over the old one).
    func install() throws(Failure) {
        guard let target else { throw .noExecutable }
        if state() == .occupied { throw .occupied }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            throw .system("Couldn't create \(displayDirectory): \(error.localizedDescription)")
        }
        let temporary = directory.appendingPathComponent(".insomnia.\(UUID().uuidString.prefix(8))")
        guard symlink(target.path, temporary.path) == 0 else { throw .system(Self.posix("Couldn't create the link")) }
        guard rename(temporary.path, link.path) == 0 else {
            let failure = Self.posix("Couldn't put the link in place")
            unlink(temporary.path)
            throw .system(failure)
        }
    }

    /// Removes our link (to this copy or another copy of Insomnia); never anything else.
    func remove() throws(Failure) {
        switch state() {
        case .notInstalled: return
        case .occupied: throw .occupied
        case .installed, .pointsElsewhere:
            guard unlink(link.path) == 0 || errno == ENOENT else { throw .system(Self.posix("Couldn't remove the link")) }
        }
    }

    // MARK: Helpers

    static func looksLikeInsomnia(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/MacOS/Insomnia")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func posix(_ what: String) -> String { "\(what): \(String(cString: strerror(errno)))." }
}

// MARK: - Is ~/.local/bin on the user's PATH?

/// A GUI app's own PATH is launchd's minimal one, so ask the user's login shell once (it may read .zprofile/.zshrc).
/// The shell runs in its own session with stdin from /dev/null, no inherited descriptors besides a pipe for stdout,
/// and is killed (with its process group) after 5 s. Unknown shells or failures → `nil`, and the UI shows no warning.
enum ShellPATH {
    enum Status: Equatable, Sendable {
        case onPath
        case missing
        /// Another `insomnia` comes first on PATH.
        case shadowed(by: String)
    }

    static func check(directory: URL, target: URL?) async -> Status? {
        await Task.detached(priority: .utility) {
            guard let entries = loginShellPATH() else { return nil }
            return evaluate(entries, directory: directory, target: target)
        }.value
    }

    /// Pure: where does `insomnia` resolve to, given PATH entries?
    static func evaluate(_ entries: [String], directory: URL, target: URL?) -> Status {
        let ours = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for entry in entries where !entry.isEmpty {
            let dir = URL(fileURLWithPath: (entry as NSString).expandingTildeInPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            if dir == ours { return .onPath }
            let candidate = (dir as NSString).appendingPathComponent("insomnia")
            if access(candidate, X_OK) == 0 {
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                if let target, resolved == target.path { return .onPath }
                return .shadowed(by: CLIInstaller.abbreviate(candidate))
            }
        }
        return .missing
    }

    private static let marker = "__INSOMNIA_PATH__"

    nonisolated static func loginShellPATH() -> [String]? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(getuid(), &entry, &storage, storage.count, &result) == 0, result != nil,
              let shellPointer = entry.pw_shell else { return nil }
        let shell = String(cString: shellPointer)
        let name = (shell as NSString).lastPathComponent
        guard ["zsh", "bash", "sh", "ksh", "dash", "fish"].contains(name), access(shell, X_OK) == 0 else { return nil }
        let script = #"printf '\n%s%s%s\n' "\#(marker)" "$PATH" "\#(marker)""#
        guard let output = run(shell, ["-l", "-i", "-c", script], timeout: 5) else { return nil }
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[parts.count - 2]
        // fish joins a quoted list with spaces on some versions; colons everywhere else.
        let separator: Character = path.contains(":") || !path.contains(" ") ? ":" : " "
        return path.split(separator: separator).map(String.init)
    }

    /// posix_spawn with CLOEXEC_DEFAULT (no descriptor of the app leaks into the user's shell) in a new session.
    private nonisolated static func run(_ executable: String, _ arguments: [String], timeout: Int) -> String? {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return nil }
        let readEnd = pipeFDs[0], writeEnd = pipeFDs[1]
        defer { close(readEnd) }

        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        // A new session: no controlling terminal for an interactive shell to grab (and stop on SIGTTOU over).
        Spawn.configureAttributes(&attr, extraFlags: Int32(POSIX_SPAWN_SETSID))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        var pid: pid_t = 0
        let rc = Spawn.withCStrings([executable] + arguments) { argv in
            Spawn.withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, executable, &actions, &attr, argv, envp)
            }
        }
        close(writeEnd)
        guard rc == 0 else { return nil }

        // Read until the answer is complete (something the profile started may keep the pipe open), EOF or the deadline.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let markerBytes = Data(marker.utf8)
        func complete() -> Bool {
            guard let first = output.range(of: markerBytes) else { return false }
            return output.range(of: markerBytes, in: first.upperBound..<output.endIndex) != nil
        }
        while !complete(), output.count < 1 << 20 {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0 else { break }
            var fds = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, remaining)
            if ready < 0 { if errno == EINTR { continue } else { break } }
            if ready == 0 { break }
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n > 0 {
                output.append(contentsOf: buffer[0..<n])
            } else if n == 0 || errno != EINTR {
                break
            }
        }
        // Let the shell exit on its own until the deadline; then stop its whole process group.
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= deadline {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            usleep(50_000)
        }
        return complete() ? String(decoding: output, as: UTF8.self) : nil
    }
}

// MARK: - Model

@MainActor
@Observable
final class CLIInstallModel {
    private(set) var state: CLIInstaller.State = .notInstalled
    private(set) var path: ShellPATH.Status?
    private(set) var errorText: String?
    private(set) var copied = false
    /// A login-shell PATH check is running ("Check Again" is disabled meanwhile).
    private(set) var isCheckingPath = false

    typealias PathChecker = @Sendable (URL, URL?) async -> ShellPATH.Status?

    /// A warning is re-checked on activation at most this often (the login shell can take seconds).
    static let pathRecheckInterval: TimeInterval = 20

    @ObservationIgnored private let installer: CLIInstaller
    @ObservationIgnored private let checkPath: PathChecker
    @ObservationIgnored private let clock: () -> Date
    /// Snapshots and previews pass a fixed `path`: never ask the shell.
    @ObservationIgnored private let pathFixed: Bool
    @ObservationIgnored private var lastPathCheck: Date?

    /// `path` non-nil skips the login-shell check (snapshots, previews).
    init(installer: CLIInstaller = .standard, path: ShellPATH.Status? = nil,
         checkPath: @escaping PathChecker = { await ShellPATH.check(directory: $0, target: $1) },
         clock: @escaping () -> Date = Date.init) {
        self.installer = installer
        self.path = path
        self.checkPath = checkPath
        self.clock = clock
        pathFixed = path != nil
        state = installer.state()
    }

    var displayPath: String { installer.displayPath }
    var displayDirectory: String { installer.displayDirectory }
    var canInstall: Bool { installer.target != nil && state != .occupied }

    /// Re-reads the link and, once a link exists, asks the login shell about PATH: the first time, then again while
    /// the answer is a warning (the user may have fixed their profile; R97), at most every `pathRecheckInterval`.
    /// `force` ("Check Again") skips the wait.
    func refresh(force: Bool = false) async {
        state = installer.state()
        guard state == .installed, !pathFixed, !isCheckingPath else { return }
        if !force, let last = lastPathCheck {
            guard path != .onPath, clock().timeIntervalSince(last) >= Self.pathRecheckInterval else { return }
        }
        isCheckingPath = true
        lastPathCheck = clock()
        let result = await checkPath(installer.directory, installer.target)
        isCheckingPath = false
        path = result
    }

    /// Forget the PATH answer: a new or removed link gets a fresh check.
    private func resetPathCheck() {
        guard !pathFixed else { return }
        path = nil
        lastPathCheck = nil
    }

    func install() {
        do {
            try installer.install()
            errorText = nil
        } catch {
            errorText = error.message
        }
        resetPathCheck()
        Task { await refresh() }
    }

    func remove() {
        do {
            try installer.remove()
            errorText = nil
        } catch {
            errorText = error.message
        }
        resetPathCheck()
        state = installer.state()
    }

    func copyPathLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CLIInstaller.pathLine, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: - View

/// Rows for the Automations tab's "Command line" section: `Section("Command line") { CLIInstallView() }`.
struct CLIInstallView: View {
    @State private var model: CLIInstallModel

    init(model: CLIInstallModel = CLIInstallModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("insomnia")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityHidden(true)
                status
                Spacer(minLength: 8)
                buttons
            }
            if let error = model.errorText {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.state {
            case .installed:
                pathNote
            case .pointsElsewhere(let other):
                caption("It points to \(other). Reinstall to use this copy.")
            case .occupied:
                caption("Something else is already there, so Insomnia leaves it alone.")
            case .notInstalled:
                EmptyView()
            }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: Pieces

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            dot
            Text(statusText)
                .foregroundStyle(model.state == .notInstalled ? .secondary : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Command line tool")
        .accessibilityValue(statusText)
    }

    /// Filled when installed, hollow when not, a triangle when something needs a look: never colour alone.
    @ViewBuilder private var dot: some View {
        switch model.state {
        case .installed:
            Circle().fill(Color(nsColor: .systemGreen)).frame(width: 8, height: 8)
        case .notInstalled:
            Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
        case .pointsElsewhere, .occupied:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).imageScale(.small)
        }
    }

    private var statusText: String {
        switch model.state {
        case .installed: return "Installed at \(model.displayPath)"
        case .notInstalled: return "Not installed"
        case .pointsElsewhere: return "Linked to another copy of Insomnia"
        case .occupied: return "\(model.displayPath) is taken"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.state {
        case .notInstalled:
            Button("Install") { model.install() }
                .disabled(!model.canInstall)
                .accessibilityLabel("Install command line tool")
        case .installed, .pointsElsewhere:
            HStack(spacing: 8) {
                Button("Reinstall") { model.install() }
                    .disabled(!model.canInstall)
                    .accessibilityLabel("Reinstall command line tool")
                Button("Remove") { model.remove() }
                    .accessibilityLabel("Remove command line tool")
            }
        case .occupied:
            EmptyView()
        }
    }

    /// Asks the login shell again now (after editing a shell profile).
    private var checkAgain: some View {
        Button("Check Again") { Task { await model.refresh(force: true) } }
            .controlSize(.small)
            .disabled(model.isCheckingPath)
            .accessibilityLabel("Check PATH again")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var pathNote: some View {
        switch model.path {
        case .missing:
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("\(model.displayDirectory) is not on your PATH. Add this to your shell profile:")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                HStack(spacing: 8) {
                    Text(CLIInstaller.pathLine)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button(model.copied ? "Copied" : "Copy") { model.copyPathLine() }
                        .controlSize(.small)
                        .accessibilityLabel("Copy PATH line")
                    checkAgain
                }
            }
            .font(.callout)
        case .shadowed(let other):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text("Another insomnia comes first on your PATH: \(other)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                checkAgain
            }
            .font(.callout)
        case .onPath:
            Text("Try `insomnia status`, or `insomnia run -- make` to stay awake for exactly one build.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}
