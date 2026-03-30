// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ollmlx",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "OllmlxCore", targets: ["OllmlxCore"]),
        .executable(name: "ollmlx", targets: ["ollmlx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "OllmlxCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "ollmlx",
            dependencies: [
                "OllmlxCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "OllmlxApp",
            dependencies: [
                "OllmlxCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/Scripts"),
            ]
        ),
        .testTarget(
            name: "OllmlxCoreTests",
            dependencies: [
                "OllmlxCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
