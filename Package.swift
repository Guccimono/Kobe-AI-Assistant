// swift-tools-version: 6.2
import PackageDescription

// Kobe, the notch front end to the Hermes agent. `swift build` / `swift test` from this file;
// scripts/bundle.sh wraps the executable into build/Kobe.app (menu bar app, no Dock icon).
let package = Package(
    name: "KobeAssistant",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Kobe", targets: ["Kobe"]),
        .executable(name: "kobe-hook", targets: ["KobeHook"]),
        .library(name: "KobeKit", targets: ["KobeKit"]),
    ],
    targets: [
        // All logic, no UI: Hermes client, chat store, notch state, drops, Claude bridge, the Stripe/GitHub/Vercel
        // services and WhatsApp (models, inbox rules, gateway parsing). Fully tested.
        .target(name: "KobeKit", resources: [.copy("Resources/Icons")]),
        // The app (SwiftUI + AppKit) as a library, so KobeTests can import it; `Kobe` is only its main.swift.
        .target(name: "KobeApp", dependencies: ["KobeKit"]),
        .executableTarget(name: "Kobe", dependencies: ["KobeApp"], path: "Sources/KobeMain"),
        // Tiny helper Claude Code hooks call; it forwards each event to Kobe over a local socket.
        .executableTarget(name: "KobeHook"),
        .testTarget(name: "KobeKitTests", dependencies: ["KobeKit"], resources: [.copy("Fixtures")]),
        // The app's own tests: AppModel and the island, headless (fake panel, fake Kobe, temp exchange folder).
        .testTarget(name: "KobeTests", dependencies: ["KobeApp", "KobeKit"]),
    ],
    swiftLanguageModes: [.v6]
)
