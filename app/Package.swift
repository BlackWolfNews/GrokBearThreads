// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Threadbare",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Threadbare", targets: ["Threadbare"]),
        .library(name: "ThreadbareCore", targets: ["ThreadbareCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // Protocol models, the JSON-RPC client, the event reducer and other
        // logic with no AppKit or SwiftUI, so it can be tested on its own.
        .target(
            name: "ThreadbareCore",
            path: "Sources/ThreadbareCore"
        ),
        .executableTarget(
            name: "Threadbare",
            dependencies: [
                "ThreadbareCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/Threadbare",
            // The AppKit side renders and measures text off the main thread
            // with non-Sendable TextKit objects confined to one thread each;
            // Swift 5 mode keeps that from drowning in Sendable errors.
            // ThreadbareCore stays in Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ThreadbareCoreTests",
            dependencies: ["ThreadbareCore"],
            path: "Tests/ThreadbareCoreTests"
        ),
        // AppKit-side checks (the composer, transcript text, renders,
        // AppModel's drafts) against the app target itself.
        .testTarget(
            name: "ThreadbareAppTests",
            dependencies: ["Threadbare", "ThreadbareCore"],
            path: "Tests/ThreadbareAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
