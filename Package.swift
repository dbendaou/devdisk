// swift-tools-version: 6.0
import PackageDescription

let library: Target = .target(
    name: "DevDiskCore",
    path: "Sources/DevDiskCore",
    swiftSettings: [.swiftLanguageMode(.v6)]
)

let tests: Target = .testTarget(
    name: "DevDiskCoreTests",
    dependencies: ["DevDiskCore"],
    path: "Tests/DevDiskCoreTests",
    swiftSettings: [.swiftLanguageMode(.v6)]
)

#if os(macOS)
let products: [Product] = [
    .library(name: "DevDiskCore", targets: ["DevDiskCore"]),
    .executable(name: "DevDisk", targets: ["DevDisk"]),
]
let targets: [Target] = [
    library,
    .executableTarget(
        name: "DevDisk",
        dependencies: ["DevDiskCore"],
        path: "Sources/DevDisk",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    tests,
]
#else
let products: [Product] = [
    .library(name: "DevDiskCore", targets: ["DevDiskCore"]),
]
let targets: [Target] = [
    library,
    tests,
]
#endif

let package = Package(
    name: "DevDisk",
    // SwiftPM otherwise defaults this package to macOS 12, which rejects
    // Observation (@Observable, @Bindable). Linux ignores Apple platforms.
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
