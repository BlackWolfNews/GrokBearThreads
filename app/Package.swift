// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Threadbear",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Threadbear", targets: ["Threadbear"]),
        .library(name: "ThreadbearCore", targets: ["ThreadbearCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // Protocol models, the JSON-RPC client, the event reducer and other
        // logic with no AppKit or SwiftUI, so it can be tested on its own.
        .target(
            name: "ThreadbearCore",
            path: "Sources/ThreadbearCore"
        ),
        .executableTarget(
            name: "Threadbear",
            dependencies: [
                "ThreadbearCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/Threadbear",
            // The AppKit side renders and measures text off the main thread
            // with non-Sendable TextKit objects confined to one thread each;
            // Swift 5 mode keeps that from drowning in Sendable errors.
            // ThreadbearCore stays in Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ThreadbearCoreTests",
            dependencies: ["ThreadbearCore"],
            path: "Tests/ThreadbearCoreTests"
        ),
        // AppKit-side checks (the composer, transcript text, renders,
        // AppModel's drafts) against the app target itself.
        .testTarget(
            name: "ThreadbearAppTests",
            dependencies: ["Threadbear", "ThreadbearCore"],
            path: "Tests/ThreadbearAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
