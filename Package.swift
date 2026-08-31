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
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "AppleBooksCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "AppleBooksCLI",
            dependencies: ["AppleBooksCore"]
        ),
        .testTarget(
            name: "AppleBooksCoreTests",
            dependencies: [
                "AppleBooksCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
