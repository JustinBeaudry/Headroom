// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "HeadroomCore",
            targets: ["HeadroomCore"]
        ),
        .executable(
            name: "headroom",
            targets: ["headroom"]
        ),
        .executable(
            name: "HeadroomApp",
            targets: ["HeadroomApp"]
        )
    ],
    targets: [
        .target(
            name: "HeadroomCore",
            dependencies: [],
            path: "Sources/HeadroomCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "headroom",
            dependencies: ["HeadroomCore"],
            path: "Sources/headroom"
        ),
        .executableTarget(
            name: "HeadroomApp",
            dependencies: ["HeadroomCore"],
            path: "Sources/HeadroomApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "HeadroomCoreTests",
            dependencies: ["HeadroomCore"],
            path: "Tests/HeadroomCoreTests"
        )
    ]
)
