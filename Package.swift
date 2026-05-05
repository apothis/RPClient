// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RPClient",
    // macOS 14 minimum is set by ONNX Runtime's SwiftPM package (Phase 6 §7.1
    // — Kokoro voice engine). Personal-tool target; the user's box is on
    // macOS 26. RPClientCore + RPClientCoreTests do not link ONNX directly,
    // but a shared package-level platform requirement is the simplest path.
    platforms: [.macOS(.v14)],
    dependencies: [
        // ONNX Runtime — used by RPClientVoice for the Kokoro TTS engine.
        // Microsoft's official SwiftPM wrapper around the ONNX Runtime
        // Objective-C bindings; ships the native runtime as a binary
        // dependency. See https://github.com/microsoft/onnxruntime-swift-package-manager
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.24.2"
        ),
    ],
    targets: [
        .executableTarget(
            name: "RPClient",
            dependencies: ["RPClientCore", "RPClientVoice"],
            path: "Sources/RPClient"
        ),
        .target(
            name: "RPClientCore",
            path: "Sources/RPClientCore",
            resources: [
                // In-app help system — markdown pages shipped as bundle
                // resources, loaded via `Bundle.module`. See HelpIndex.swift.
                .process("Help"),
            ],
            swiftSettings: [
                // Enables `@testable import RPClientCore` from the test runner in debug builds.
                // Scoped to debug so release builds (the .app) are unaffected.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
            ]
        ),
        // Voice engines — isolates the ONNX Runtime dependency so the test
        // target (which only depends on RPClientCore) doesn't link the
        // ~50 MB native runtime. Phase 6 §7.1.
        .target(
            name: "RPClientVoice",
            dependencies: [
                "RPClientCore",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/RPClientVoice"
        ),
        .executableTarget(
            name: "RPClientCoreTests",
            dependencies: ["RPClientCore"],
            path: "Tests/RPClientCoreTests"
        ),
        // Phase 6 §7.1k3 prep — one-shot ONNX session introspection so we
        // can confirm which Kokoro export the bundled model is (newer
        // `input_ids` vs. legacy `tokens`) before `KokoroEngine` is written.
        // Throwaway-grade utility; run with `swift run KokoroProbe <path>`.
        .executableTarget(
            name: "KokoroProbe",
            dependencies: ["RPClientVoice"],
            path: "Sources/KokoroProbe"
        ),
    ]
)
