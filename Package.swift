// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stower",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "StowerCore", targets: ["StowerCore"]),
        .library(name: "StowerPhotos", targets: ["StowerPhotos"]),
        .library(name: "StowerMessages", targets: ["StowerMessages"]),
        .library(name: "StowerMacUI", targets: ["StowerMacUI"]),
        .executable(name: "stower", targets: ["StowerCLI"]),
        .executable(name: "stower-chatdb-inspector", targets: ["StowerChatDBInspector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/mattt/Madrid", exact: "0.4.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.17"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "StowerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/StowerCore",
            exclude: ["README.md"]
        ),
        .target(
            name: "StowerPhotos",
            dependencies: ["StowerCore"],
            path: "Sources/StowerPhotos",
            exclude: ["README.md"]
        ),
        .target(
            name: "StowerMessages",
            dependencies: [
                "StowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TypedStream", package: "Madrid"),
            ],
            path: "Sources/StowerMessages"
        ),
        .target(
            name: "StowerMacUI",
            dependencies: [
                "StowerCore",
                "StowerMessages",
                // No TelemetryDeck, no Sentry — MAS target excludes those files
                // from its compile sources at the Xcode project level.
            ],
            path: "Sources/StowerMacUI"
        ),
        .executableTarget(
            name: "StowerCLI",
            dependencies: [
                "StowerCore",
                "StowerMessages",
                "StowerMacUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StowerCLI"
        ),
        .executableTarget(
            name: "StowerChatDBInspector",
            dependencies: [
                "StowerMessages",
                "StowerMacUI",
            ],
            path: "Sources/StowerChatDBInspector"
        ),
        .testTarget(
            name: "StowerCoreTests",
            dependencies: [
                "StowerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Tests/StowerCoreTests"
        ),
        .testTarget(
            name: "StowerPhotosTests",
            dependencies: [
                "StowerPhotos",
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerPhotosTests"
        ),
        .testTarget(
            name: "StowerMessagesTests",
            dependencies: [
                "StowerMessages",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ],
            path: "Tests/StowerMessagesTests"
        ),
        .testTarget(
            name: "StowerMacUITests",
            dependencies: ["StowerCore", "StowerMacUI", "StowerMessages"],
            path: "Tests/StowerMacUITests"
        ),
    ]
)