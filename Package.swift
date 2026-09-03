// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleBooksCLI",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "AppleBooksCore", targets: ["AppleBooksCore"]),
        .executable(name: "applebookscli", targets: ["AppleBooksCLI"]),
        .executable(name: "applebookscli-pdf-worker", targets: ["AppleBooksPDFWorker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "AppleBooksCloudBridge",
            path: "Sources/AppleBooksCloudBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreData"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "AppleBooksCore",
            dependencies: [
                "AppleBooksCloudBridge",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "AppleBooksCLI",
            dependencies: [
                "AppleBooksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "AppleBooksPDFWorker",
            dependencies: ["AppleBooksCore"]
        ),
        .testTarget(
            name: "AppleBooksCoreTests",
            dependencies: [
                "AppleBooksCloudBridge",
                "AppleBooksCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "AppleBooksCLITests",
            dependencies: ["AppleBooksCLI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
