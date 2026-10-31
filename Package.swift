// swift-tools-version:6.0
import PackageDescription

// Three targets (ARCHITECTURE.md "Build model"):
//   Insomnia        the app (menu bar + Dock + CLI dispatch)          → Contents/MacOS/Insomnia
//   InsomniaHelper  root launchd daemon, SMAppService.daemon + XPC    → Contents/MacOS/InsomniaHelper
//   InsomniaShared  XPC protocol, identifiers, code-signing requirements; linked statically into both
let package = Package(
    name: "Insomnia",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "InsomniaShared",
            path: "Sources/InsomniaShared",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "Insomnia",
            dependencies: ["InsomniaShared"],
            path: "Sources/Insomnia",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
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
    ],
    swiftLanguageModes: [.v6]
)
