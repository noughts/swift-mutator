// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-mutator",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swift-mutator", targets: ["MutatorCLI"]),
        .library(name: "MutatorCore", targets: ["MutatorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        // Pure functions only: instrumentation, planning, diff selection, report formatting.
        .target(
            name: "MutatorCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ]
        ),
        // I/O boundary: file system, git, swift build, test processes.
        .executableTarget(name: "MutatorCLI", dependencies: ["MutatorCore"]),
        .testTarget(name: "MutatorCoreTests", dependencies: ["MutatorCore"]),
        // End to end: real `swift build`, test processes and snapshots on a copy of Examples/Pricing.
        .testTarget(name: "MutatorCLITests", dependencies: ["MutatorCLI", "MutatorCore"]),
    ]
)
