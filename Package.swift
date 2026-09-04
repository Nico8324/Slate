// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Slate",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "Slate", targets: ["Slate"])
    ],
    targets: [
        .target(name: "Slate"),
        .testTarget(name: "SlateTests", dependencies: ["Slate"])
    ],
    swiftLanguageModes: [.v6]
)
