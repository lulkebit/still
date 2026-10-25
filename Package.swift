// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Still",
    defaultLocalization: "de",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "still", targets: ["Still"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        .package(url: "https://github.com/gonzalezreal/textual.git", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Still",
            dependencies: [.product(name: "MCP", package: "swift-sdk"), .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "Textual", package: "textual")],
            resources: [.copy("Resources/Editor"), .process("Resources/de.lproj"), .copy("Resources/THIRD_PARTY_NOTICES.txt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StillTests",
            dependencies: ["Still"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
