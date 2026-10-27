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
    ],
    swiftLanguageModes: [.v6]
)
