// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ebb",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "EbbCore"),
        .executableTarget(name: "Ebb", dependencies: ["EbbCore"]),
        .testTarget(
            name: "EbbCoreTests",
            dependencies: ["EbbCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
