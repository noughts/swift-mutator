// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pricing",
    targets: [
        .target(name: "Pricing"),
        .testTarget(name: "PricingTests", dependencies: ["Pricing"]),
    ]
)
