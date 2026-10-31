// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Insomnia",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Insomnia",
            path: "Sources/Insomnia",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
