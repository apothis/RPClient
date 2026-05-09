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
                // Phase 9 §5.4.a — bundled AI-assist prompt template
                // registry, loaded via `Bundle.module` by
                // CardGenPromptsLoader. Read-only; user override deferred
                // to V2_UI_OVERHAUL.
                .process("AI/Bundled"),
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
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Tests/RPClientCoreTests"
        ),
        // Phase 10 §10.0.a — shared fixtures used by every model-interaction
        // smoke binary (ChatSmoke, SummariserSmoke, ExtractorSmoke,
        // BlurberSmoke, DirectorSmoke, EmbedSmoke). Library, not
        // executable: `SyntheticChats` / `SyntheticCharacters` /
        // `RealChatLoader`. `-enable-testing` so the smokes can
        // `@testable import SmokeFixtures` and reach internal types
        // (mirrors the RPClientCore convention; CardGenSmoke does the
        // same for RPClientCore). See V2_PHASE10_SMOKE_HARNESS_PLAN.md.
        .target(
            name: "SmokeFixtures",
            dependencies: ["RPClientCore"],
            path: "Sources/SmokeFixtures",
            swiftSettings: [
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
            ]
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
        // Phase 6 §7.1k3 first-light smoke runner — end-to-end pipeline
        // from text → espeak-ng → tokenize → KokoroEngine → write WAV.
        // Acceptance is "does it sound like speech?" — no automated check.
        // Run with `swift run KokoroSmoke "Hello, world."` then `afplay`.
        .executableTarget(
            name: "KokoroSmoke",
            dependencies: ["RPClientCore", "RPClientVoice"],
            path: "Sources/KokoroSmoke"
        ),
        // Phase 9 §5.4.a smoke runner — drives a real
        // CardSuggestionsController against a real KoboldCPP server,
        // prints the triad's state transitions + final candidates.
        // Uses @testable import to reach internal types
        // (KoboldClient, Templates, etc); runs only in debug builds.
        // Run with `swift run CardGenSmoke [server-url] [template] [field] [tags]`.
        .executableTarget(
            name: "CardGenSmoke",
            dependencies: ["RPClientCore"],
            path: "Sources/CardGenSmoke"
        ),
        // Phase 10 §10.0.b — chat-path smoke runner. Drives
        // KoboldClient.generateStream against prompts assembled by
        // PromptBuilder from the SmokeFixtures catalogue. Most
        // load-bearing model-facing surface in the app — exercises
        // template selection, stop sequences, system prompt, persona,
        // world-info injection, memory prefix, multi-cast assembly.
        // Run with `swift run ChatSmoke [--server …] [--fixture …] [--verbose]`.
        .executableTarget(
            name: "ChatSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/ChatSmoke"
        ),
        // Phase 10 §10.0.c — summariser smoke. Drives Summarizer.run
        // against long-history fixtures to exercise the rolling-summary
        // side-call (and the "wrap a single user turn through PromptBuilder"
        // pattern that all side-calls share).
        // Run with `swift run SummariserSmoke [--fixture sfw-long] [--ctx N]`.
        .executableTarget(
            name: "SummariserSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/SummariserSmoke"
        ),
        // Phase 10 §10.0.c — director smoke. Drives DirectorPicker.next
        // against multi-cast fixtures to exercise the speaker-router
        // side-call (5s internal timeout, substring-match parser,
        // round-robin fallback on nil).
        // Run with `swift run DirectorSmoke [--fixture group-chat] [--repeats N]`.
        .executableTarget(
            name: "DirectorSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/DirectorSmoke"
        ),
        // Phase 10 §10.0.d — extractor smoke. Drives FactExtractor.run
        // (GBNF JSON-mode side call) against long-history fixtures.
        // Validates schema conformance + non-emptiness.
        // Run with `swift run ExtractorSmoke [--fixture sfw-long] [--last-n N]`.
        .executableTarget(
            name: "ExtractorSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/ExtractorSmoke"
        ),
        // Phase 10 §10.0.d — context-blurber smoke. Drives ContextBlurber.run
        // against a synthetic mid-chat chunk; validates 1–2 short factual
        // sentences (no thinking-trace leak, no refusal, length-bounded).
        // Run with `swift run BlurberSmoke [--fixture sfw-long]`.
        .executableTarget(
            name: "BlurberSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/BlurberSmoke"
        ),
        // Phase 10 §10.0.d — embeddings smoke. Smallest harness:
        // confirms /v1/embeddings is reachable, returns vectors of
        // consistent dimensionality.
        // Run with `swift run EmbedSmoke [--fixture all]`.
        .executableTarget(
            name: "EmbedSmoke",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/EmbedSmoke"
        ),
        // Phase 10 §10.0.e — aggregate runner. Spawns each per-surface
        // smoke as a sub-process, captures timing + exit, snapshots the
        // per-EXACT-model observation log to smoke-reports/<name>-<ts>.json,
        // and supports `--diff <prior>` for regression detection across
        // runs (or across model swaps).
        // Run with `swift build && swift run SmokeAll`.
        .executableTarget(
            name: "SmokeAll",
            dependencies: ["RPClientCore", "SmokeFixtures"],
            path: "Sources/SmokeAll"
        ),
    ]
)
