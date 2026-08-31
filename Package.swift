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
    ],
    targets: [
        .target(
            name: "AppleBooksCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .executableTarget(
            name: "AppleBooksCLI",
            dependencies: ["AppleBooksCore"]
        ),
        .testTarget(
            name: "AppleBooksCoreTests",
            dependencies: ["AppleBooksCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
