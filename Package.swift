// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapIt",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SnapItCore", targets: ["SnapItCore"]), .executable(name: "SnapIt", targets: ["SnapIt"])],
    targets: [
        .target(name: "SnapItCore"),
        // AppKit, Carbon and ScreenCaptureKit glue. Swift 5 mode keeps their non-Sendable types workable.
        .executableTarget(name: "SnapIt", dependencies: ["SnapItCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SnapItCoreTests", dependencies: ["SnapItCore"])
    ]
)
