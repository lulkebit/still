// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Still",
    defaultLocalization: "de",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "still", targets: ["Still"])
    ],
    targets: [
        .executableTarget(
            name: "Still",
            resources: [.copy("Resources/Editor"), .process("Resources/de.lproj")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StillTests",
            dependencies: ["Still"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
