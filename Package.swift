// swift-tools-version: 6.0
// The whole build is defined here: no .xcodeproj. `swift build` / `swift test` work from the
// terminal on macOS and Linux, and Xcode can open this folder directly.
import PackageDescription

var products: [Product] = [
    .executable(name: "atdrive", targets: ["atdrive"]),
    .library(name: "ATDriveCore", targets: ["ATDriveCore"]),
]

var targets: [Target] = [
    // Everything that isn't UI: protocol client, identity, auth, the drive model.
    // Shared by the CLI, the macOS app and File Provider extension, and (later) Linux FUSE.
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

#if os(macOS)
    // The Finder integration. `scripts/build-app.sh` packages these two executables as
    // ATDrive.app with ATDriveFileProvider.appex inside it, and signs them.
    // Swift 5 mode: Apple's FileProvider APIs aren't fully annotated for strict concurrency yet.
    let appleSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    products += [
        .executable(name: "ATDriveApp", targets: ["ATDriveApp"]),
        .executable(name: "ATDriveFileProvider", targets: ["ATDriveFileProvider"]),
    ]
    targets += [
        // Shared by the app and the extension: App Group lookup and the Finder domain.
        .target(
            name: "ATDriveMacSupport",
            dependencies: ["ATDriveCore"],
            path: "Sources/Mac/Support",
            swiftSettings: appleSettings
        ),
        // The menu-bar app: sign in, add the drive to Finder.
        .executableTarget(
            name: "ATDriveApp",
            dependencies: ["ATDriveCore", "ATDriveMacSupport"],
            path: "Sources/Mac/App",
            swiftSettings: appleSettings
        ),
        // The File Provider extension: does the actual syncing for Finder.
        // Like Xcode, it has no `main`: the linker makes Foundation's NSExtensionMain the entry
        // point. (Calling NSExtensionMain from a main.swift recurses: the extension runtime calls
        // the binary's `main` again, until the stack overflows.)
        .executableTarget(
            name: "ATDriveFileProvider",
            dependencies: ["ATDriveCore", "ATDriveMacSupport"],
            path: "Sources/Mac/FileProvider",
            swiftSettings: appleSettings,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
#endif

let package = Package(
    name: "ATDrive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        // CryptoKit's API on Linux (on Apple platforms it just re-exports CryptoKit).
        .package(url: "https://github.com/apple/swift-crypto", from: "5.1.0"),
    ],
    targets: targets
)
