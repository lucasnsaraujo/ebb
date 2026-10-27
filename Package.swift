// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ebb",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Each String Catalog is the source of the .lproj folders beside it, made by `xcstringstool compile`
        // and kept in step by CompiledCatalogTests. The folders are the resources: SwiftPM's older build
        // system copies a catalog raw, so an app built with it would have no Portuguese at all.
        .target(name: "EbbCore", exclude: ["Resources/EbbCore.xcstrings"], resources: [.process("Resources")]),
        .executableTarget(
            name: "Ebb",
            dependencies: ["EbbCore", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources/Localizable.xcstrings", "Resources/AppShortcuts.xcstrings"],
            resources: [.process("Resources")],
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
        .testTarget(name: "EbbAppTests", dependencies: ["Ebb", "EbbCore"]),
    ]
)
