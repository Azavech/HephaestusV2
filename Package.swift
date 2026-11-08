// swift-tools-version: 6.2
// Modules and dependency rules: docs/architecture.md › Modules.
import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "HephaestusV2",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "HephaestusCore",
            dependencies: ["HephaestusText", .product(name: "Yams", package: "Yams")],
            resources: [.copy("Resources/prompts")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HephaestusText",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "HephaestusUI",
            dependencies: ["HephaestusCore", "HephaestusText", "UpdaterCore"],
            resources: [.copy("Resources")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "HephaestusV2",
            dependencies: ["HephaestusUI"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "UpdaterCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Updater",
            dependencies: ["UpdaterCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HephaestusCoreTests",
            dependencies: ["HephaestusCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HephaestusTextTests",
            dependencies: ["HephaestusText"],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HephaestusUITests",
            dependencies: ["HephaestusUI", "HephaestusCore", "UpdaterCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "UpdaterCoreTests",
            dependencies: ["UpdaterCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
