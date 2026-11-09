// swift-tools-version: 6.0
// The whole build is defined here: no .xcodeproj. `swift build` / `swift test` work from the
// terminal on macOS and Linux, and Xcode can open this folder directly.
import PackageDescription

let package = Package(
    name: "ATDrive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "atdrive", targets: ["atdrive"]),
        .library(name: "ATDriveCore", targets: ["ATDriveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        // CryptoKit's API on Linux (on Apple platforms it just re-exports CryptoKit).
        .package(url: "https://github.com/apple/swift-crypto", from: "5.1.0"),
    ],
    targets: [
        // Everything that isn't UI: protocol client, identity, auth, the drive model.
        // Shared by the CLI now and the macOS/iOS File Provider extension and Linux FUSE later.
        .target(
            name: "ATDriveCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "atdrive",
            dependencies: [
                "ATDriveCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ATDriveCoreTests",
            dependencies: ["ATDriveCore"]
        ),
    ]
)
