// swift-tools-version: 6.2
import PackageDescription

// The phone app's logic with no UIKit or SwiftUI: the Convex rows, the
// inbox's order, the Convex transport and a fake backend for screenshots
// and the simulator. Builds for macOS too, so `swift test` runs here.
let package = Package(
    name: "ThreadbearKit",
    platforms: [.iOS("18.0"), .macOS("26.2")],
    products: [
        .library(name: "ThreadbearKit", targets: ["ThreadbearKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.1"),
    ],
    targets: [
        .target(
            name: "ThreadbearKit",
            dependencies: [.product(name: "ConvexMobile", package: "convex-swift")]
        ),
        .testTarget(name: "ThreadbearKitTests", dependencies: ["ThreadbearKit"]),
        // Quick ask's logic (listening, early sending, the server's answer stream, speaking a
        // sentence at a time). The app compiles these files itself, from Threadbear/QuickAskCore,
        // where this target's folder is a link to; the package builds them only so `swift test`
        // runs their tests on the Mac. Main-actor by default, as in the app.
        .target(
            name: "QuickAskCore",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "QuickAskCoreTests",
            dependencies: ["QuickAskCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
