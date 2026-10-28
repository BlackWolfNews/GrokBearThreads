// swift-tools-version: 6.2
import PackageDescription

// BearDock: dockable, rearrangeable panels for Threadbear, kept in its own
// package with a demo app so the feel of dragging and docking can be got
// right before it goes into the real window.
let package = Package(
    name: "BearDock",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "BearDock", targets: ["BearDock"]),
        .executable(name: "DockDemo", targets: ["DockDemo"]),
    ],
    targets: [
        .target(name: "BearDock"),
        .executableTarget(name: "DockDemo", dependencies: ["BearDock"]),
        .testTarget(name: "BearDockTests", dependencies: ["BearDock"]),
    ]
)
