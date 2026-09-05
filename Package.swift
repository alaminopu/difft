// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Difft",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.0"),
    ],
    targets: [
        .target(name: "DifftCore"),
        .target(name: "DifftServices", dependencies: ["DifftCore"]),
        .target(name: "DifftUI", dependencies: ["DifftCore", "DifftServices", "Highlightr"]),
        .executableTarget(name: "Difft", dependencies: ["DifftCore", "DifftServices", "DifftUI"]),
        .testTarget(name: "DifftCoreTests", dependencies: ["DifftCore"]),
        .testTarget(name: "DifftServicesTests", dependencies: ["DifftServices"]),
        .testTarget(name: "DifftUITests", dependencies: ["DifftUI"]),
    ]
)
