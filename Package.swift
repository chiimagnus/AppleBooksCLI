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
    targets: [
        .target(name: "AppleBooksCore"),
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
