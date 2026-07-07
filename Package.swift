// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchReminder",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "ReminderCore",
            path: "Sources/ReminderCore"
        ),
        .executableTarget(
            name: "NotchReminder",
            dependencies: [
                "ReminderCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/NotchReminder"
        ),
        .testTarget(
            name: "ReminderCoreTests",
            dependencies: ["ReminderCore"],
            path: "Tests/ReminderCoreTests"
        ),
        .testTarget(
            name: "NotchReminderTests",
            dependencies: ["NotchReminder", "ReminderCore"],
            path: "Tests/NotchReminderTests"
        )
    ]
)
