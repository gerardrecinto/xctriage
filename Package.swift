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
        // Linux-only: FailureFingerprint's SHA256 hash needs an API-compatible
        // stand-in for CryptoKit, which doesn't exist outside Apple platforms.
        .package(
            url: "https://github.com/apple/swift-crypto",
            from: "3.0.0"
        ),
    ],
    targets: [
        // Linux-only: `import SQLite3` resolves against a module Apple's SDK
        // provides implicitly; `libsqlite3-dev` on Linux has no module map,
        // so this wraps the same header the SwiftPM way.
        .systemLibrary(
            name: "CSQLite3",
            path: "Sources/CSQLite3"
        ),
        .target(
            name: "XCTriageKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .target(name: "CSQLite3", condition: .when(platforms: [.linux])),
            ],
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
