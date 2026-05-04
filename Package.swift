// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RPClient",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RPClient",
            dependencies: ["RPClientCore"],
            path: "Sources/RPClient"
        ),
        .target(
            name: "RPClientCore",
            path: "Sources/RPClientCore",
            swiftSettings: [
                // Enables `@testable import RPClientCore` from the test runner in debug builds.
                // Scoped to debug so release builds (the .app) are unaffected.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "RPClientCoreTests",
            dependencies: ["RPClientCore"],
            path: "Tests/RPClientCoreTests"
        ),
    ]
)
