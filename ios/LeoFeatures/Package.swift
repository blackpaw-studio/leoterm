// swift-tools-version: 6.2
import PackageDescription

// The iOS app's reducers, models and dependency clients. UIKit-free, so the
// feature tests also run on macOS with `swift test`; the app target owns the
// view controllers and the VisionKit scanner.
let package = Package(
    name: "LeoFeatures",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "LeoFeatures", targets: ["LeoFeatures"]),
    ],
    dependencies: [
        .package(path: "../../Packages/LeoKit"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.26.2"),
        .package(url: "https://github.com/pointfreeco/swift-navigation", exact: "2.11.2"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"),
    ],
    targets: [
        .target(
            name: "LeoFeatures",
            dependencies: [
                "LeoKit",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "LeoFeaturesTests",
            dependencies: [
                "LeoFeatures",
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ]
        ),
    ]
)
