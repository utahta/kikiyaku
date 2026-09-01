// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kikiyaku",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "kikiyaku",
            path: "Sources/kikiyaku",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "kikiyakuTests",
            dependencies: ["kikiyaku"],
            path: "Tests/kikiyakuTests"
        ),
    ]
)
