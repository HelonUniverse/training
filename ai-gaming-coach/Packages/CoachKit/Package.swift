// swift-tools-version:5.9
import PackageDescription

// CoachCore is deliberately free of Apple-only frameworks (no AVFoundation,
// UIKit, ReplayKit). Everything here compiles and is unit-tested on Linux,
// so the engine can later sit behind Android/Windows/console capture sources.
let package = Package(
    name: "CoachKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoachCore", targets: ["CoachCore"]),
    ],
    targets: [
        .target(name: "CoachCore"),
        .testTarget(name: "CoachCoreTests", dependencies: ["CoachCore"]),
    ]
)
