// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xctriage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
    ],
    targets: [
        .target(
            name: "XCTriageKit",
            path: "Sources/XCTriageKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "xctriage",
            dependencies: [
                "XCTriageKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/xctriage"
        ),
        .testTarget(
            name: "XCTriageKitTests",
            dependencies: ["XCTriageKit"],
            path: "Tests/XCTriageKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
