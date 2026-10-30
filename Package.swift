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
        .package(path: "Vendor/swift-sdk"),
        .package(path: "Vendor/SwiftSoup"),
        .package(path: "Vendor/textual")
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
