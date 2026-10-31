import Darwin
import Foundation

/// The .app the helper runs from, derived from the kernel's idea of our executable path (proc_pidpath), not from
/// argv or Bundle lookups: …/Insomnia.app/Contents/MacOS/InsomniaHelper → …/Insomnia.app.
enum HelperBundle {
    static func url() -> URL {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(getpid(), &buf, UInt32(buf.count))
        let path = n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : (CommandLine.arguments.first ?? "")
        return bundleURL(forExecutable: URL(fileURLWithPath: path))
    }

    /// Strips `Contents/MacOS/<exe>`. A binary not inside a bundle yields its own directory, which never passes
    /// InstallLocation.check (wrong path), so the helper stays reset-only.
    static func bundleURL(forExecutable exe: URL) -> URL {
        let macOS = exe.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" else { return macOS }
        return contents.deletingLastPathComponent()
    }
}
