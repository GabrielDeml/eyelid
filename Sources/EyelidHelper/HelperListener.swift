import Foundation
import EyelidShared

/// Accepts connections that already passed the listener's code-signing requirement (set before `resume()`, so a bad
/// peer never reaches this delegate). One connection == one session.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let daemon: HelperDaemon

    init(daemon: HelperDaemon) {
        self.daemon = daemon
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = HelperSession(daemon: daemon, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = session
        let lost: @Sendable () -> Void = { [weak session, daemon] in
            guard let session else { return }
            daemon.queue.async { daemon.connectionInvalidated(session) }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        HelperLog.xpc.info("accepted a client (pid \(session.pid, privacy: .public), uid \(session.uid, privacy: .public))")
        return true
    }
}

/// The exported object for one client connection. Its mutable fields belong to the daemon's queue; every XPC method
/// hops onto that queue before touching anything. No arguments, no paths, no strings from the client.
final class HelperSession: NSObject, HelperProtocol, @unchecked Sendable {
    private let daemon: HelperDaemon
    weak var connection: NSXPCConnection?
    let uid: UInt32
    let pid: Int32

    // Daemon queue only.
    var engaged = false
    var dropReason: HelperResult?
    var deadline: DispatchSourceTimer?

    init(daemon: HelperDaemon, connection: NSXPCConnection) {
        self.daemon = daemon
        self.connection = connection
        self.uid = connection.effectiveUserIdentifier
        self.pid = connection.processIdentifier
    }

    deinit {
        deadline?.cancel()
    }

    func status(withReply reply: @escaping @Sendable (String, String, Bool, Bool) -> Void) {
        daemon.queue.async { [daemon] in daemon.status(self, reply) }
    }

    func engage(withReply reply: @escaping @Sendable (Int32, Bool) -> Void) {
        daemon.queue.async { [daemon] in daemon.engage(self, reply) }
    }

    func release(withReply reply: @escaping @Sendable (Int32, Bool) -> Void) {
        daemon.queue.async { [daemon] in daemon.release(self, reply) }
    }

    func heartbeat(withReply reply: @escaping @Sendable (Int32) -> Void) {
        daemon.queue.async { [daemon] in daemon.heartbeat(self, reply) }
    }
}
