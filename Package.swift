// swift-tools-version:6.0
import PackageDescription

// Three targets (docs/DESIGN.md) plus the InsomniaTests test target:
//   Insomnia        the menu bar app                                  → Contents/MacOS/Insomnia
//   InsomniaHelper  root launchd daemon, SMAppService.daemon + XPC    → Contents/MacOS/InsomniaHelper
//   InsomniaShared  XPC protocol, identifiers, code-signing requirements; linked statically into both
let package = Package(
    name: "Insomnia",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "InsomniaShared",
            path: "Sources/InsomniaShared",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "Insomnia",
            dependencies: ["InsomniaShared"],
            path: "Sources/Insomnia",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "InsomniaHelper",
            dependencies: ["InsomniaShared"],
            path: "Sources/InsomniaHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        // Engine and lid controller with fakes, helper policy, power parsing. Swift Testing.
        // `@testable import Insomnia` works because SwiftPM builds executable targets testable on macOS.
        .testTarget(
            name: "InsomniaTests",
            dependencies: ["Insomnia"],
            path: "Tests/InsomniaTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
