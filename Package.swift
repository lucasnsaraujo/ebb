// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ebb",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "EbbCore"),
        .executableTarget(name: "Ebb", dependencies: ["EbbCore"]),
        // Shipped in the app bundle as Contents/Helpers/ebb; named apart from Ebb for case-insensitive disks.
        .executableTarget(name: "EbbCLI", dependencies: ["EbbCore"]),
        .testTarget(
            name: "EbbCoreTests",
            dependencies: ["EbbCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
