// swift-tools-version: 6.2
import PackageDescription

// Matches the Leo macOS app target's Swift settings (Swift 5 language mode,
// Approachable Concurrency, MemberImportVisibility) so code moved out of the
// app keeps its exact isolation semantics.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "LeoKit",
    platforms: [.macOS(.v13), .iOS(.v26)],
    products: [
        .library(name: "LeoKit", targets: ["LeoKit"]),
    ],
    targets: [
        .target(name: "LeoKit", swiftSettings: swiftSettings),
        .testTarget(
            name: "LeoKitTests",
            dependencies: ["LeoKit"],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
    ]
)
