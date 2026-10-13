// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirada",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiradaKit", targets: ["MiradaKit"]),
        .library(name: "MiradaArt", targets: ["MiradaArt"]),
        .executable(name: "mirada", targets: ["mirada"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "MiradaArt"),
        // Dev tool: renders the app icon and artwork from MiradaArt.
        .executableTarget(name: "mirada-art", dependencies: ["MiradaArt"]),
        .target(
            name: "MiradaKit",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "mirada",
            dependencies: [
                "MiradaKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embeds Info.plist so camera permission prompts name Mirada.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "Sources/mirada/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MiradaKitTests",
            dependencies: ["MiradaKit"]
        ),
    ]
)
