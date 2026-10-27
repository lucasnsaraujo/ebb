// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ebb",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "EbbCore"),
        .executableTarget(
            name: "Ebb",
            dependencies: ["EbbCore", .product(name: "Sparkle", package: "Sparkle")],
            // build.sh copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Shipped in the app bundle as Contents/Helpers/ebb; named apart from Ebb for case-insensitive disks.
        .executableTarget(name: "EbbCLI", dependencies: ["EbbCore"]),
        .testTarget(
            name: "EbbCoreTests",
            dependencies: ["EbbCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
