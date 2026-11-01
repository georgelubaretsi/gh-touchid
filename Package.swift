// swift-tools-version: 6.0

// gh-touchid itself is built by scripts/build.sh with swiftc and links no third-party code; its target is here for
// editors. The adapter behind `gh-touchid rpc|mcp` is a separate program built from this manifest by the same script
// (`swift build`), since it uses the official MCP Swift SDK, pinned to one exact version with Package.resolved.

import PackageDescription

let package = Package(
    name: "gh-touchid",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "gh-touchid", targets: ["GHTouchID"]),
        .executable(name: "gh-touchid-adapter", targets: ["GHTouchIDAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(name: "GHTouchID"),
        .executableTarget(
            name: "GHTouchIDAdapter",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
