// swift-tools-version:6.0
import PackageDescription

// Three targets (docs/DESIGN.md) plus the EyelidTests test target:
//   Eyelid        the menu bar app                                  → Contents/MacOS/Eyelid
//   EyelidHelper  root launchd daemon, SMAppService.daemon + XPC    → Contents/MacOS/EyelidHelper
//   EyelidShared  XPC protocol, identifiers, code-signing requirements; linked statically into both
let package = Package(
    name: "Eyelid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "EyelidShared",
            path: "Sources/EyelidShared",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "Eyelid",
            dependencies: ["EyelidShared"],
            path: "Sources/Eyelid",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "EyelidHelper",
            dependencies: ["EyelidShared"],
            path: "Sources/EyelidHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        // Engine and lid controller with fakes, helper policy, power parsing. Swift Testing.
        // `@testable import Eyelid` works because SwiftPM builds executable targets testable on macOS.
        .testTarget(
            name: "EyelidTests",
            dependencies: ["Eyelid"],
            path: "Tests/EyelidTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
