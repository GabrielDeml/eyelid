import Foundation
import InsomniaShared

// InsomniaHelper: root launchd daemon (SMAppService.daemon). Implemented in M2 per docs/CLOSED_LID.md §2.
// Until then this stub refuses to run so a half-built helper can never hold SleepDisabled. It exits 0: the launchd
// plist uses KeepAlive = { SuccessfulExit = false }, so a clean exit is never respawned (and build.sh does not bundle
// the plist until the helper is implemented).
FileHandle.standardError.write(Data("\(HelperInfo.label) \(HelperInfo.version): not implemented yet\n".utf8))
exit(0)
