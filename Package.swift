// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Difft",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored rather than fetched: SwiftPM's generated Bundle.module
        // cannot find resources inside a signed .app, so the app crashed at
        // launch on every machine but the one that built it. See
        // Vendor/Highlightr/PATCH.md.
        .package(path: "Vendor/Highlightr"),
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
