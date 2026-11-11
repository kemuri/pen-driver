// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wdrive",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic: HID descriptor parsing, area mapping, click guard. No IOKit, fully testable.
        .target(name: "PenCore"),
        // The app: real-time HID thread, CGEvent output, SwiftUI settings window.
        .executableTarget(name: "wdrive", dependencies: ["PenCore"]),
        .testTarget(name: "PenCoreTests", dependencies: ["PenCore"]),
    ],
    swiftLanguageModes: [.v5]
)
