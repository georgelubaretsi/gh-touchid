// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "gh-touchid",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gh-touchid", targets: ["GHTouchID"]),
    ],
    targets: [
        .executableTarget(name: "GHTouchID"),
    ]
)
