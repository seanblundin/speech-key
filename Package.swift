// swift-tools-version: 6.0
import PackageDescription

// The App Store build (SPEECHKEY_APPSTORE=1 scripts/build-app.sh) leaves out Sparkle, since the
// Store updates apps itself. The website build checks speechkeyapp.com/appcast.xml for updates.
let appStore = Context.environment["SPEECHKEY_APPSTORE"] != nil

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS("14.2")],   // 14.2 for Core Audio process taps (meeting mode)
    products: [
        // The shared engine. Meeting mode (meeting/) depends on this product by local path.
        .library(name: "SpeechEngine", targets: ["SpeechEngine", "TranscriptText"]),
        // The app, SpeechKey (named Utter until 2026-10-20; the target keeps the old name).
        .executable(name: "SpeechKey", targets: ["Utter"]),
        .executable(name: "engine-bench", targets: ["EngineBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ] + (appStore ? [] : [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ]),
    targets: [
        // Pure text: glossary fixes and clean-verbatim rules. No dependencies, so it builds and tests fast.
        .target(
            name: "TranscriptText",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure key-chord rules for the fn key, testable without a keyboard.
        .target(name: "Hotkeys"),
        .target(
            name: "SpeechEngine",
            dependencies: [
                "TranscriptText",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Utter",
            dependencies: ["SpeechEngine", "Hotkeys"]
                + (appStore ? [] : [.product(name: "Sparkle", package: "Sparkle")]),
            swiftSettings: [.swiftLanguageMode(.v5)] + (appStore ? [.define("APPSTORE")] : []),
            // Sparkle.framework sits in Contents/Frameworks of the app bundle.
            linkerSettings: appStore ? [] : [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "EngineBench",
            dependencies: ["SpeechEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscriptTextTests",
            dependencies: ["TranscriptText"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys"]),
    ]
)
