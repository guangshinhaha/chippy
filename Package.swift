// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chippy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Chippy", targets: ["Chippy"]),
        .executable(name: "chippy-hook", targets: ["chippy-hook"]),
    ],
    targets: [
        .target(name: "ChippyCore"),
        .executableTarget(name: "Chippy", dependencies: ["ChippyCore"]),
        .executableTarget(name: "chippy-hook", dependencies: ["ChippyCore"]),
        .testTarget(name: "ChippyCoreTests", dependencies: ["ChippyCore", "Chippy"]),
    ]
)
