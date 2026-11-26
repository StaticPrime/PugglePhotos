// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PugglePhotosKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PugglePhotosKit", targets: ["PugglePhotosKit"]),
        // Keeping the app up to date: shared by the app and its update installer service.
        .library(name: "PuggleUpdate", targets: ["PuggleUpdate"]),
    ],
    targets: [
        .target(name: "PugglePhotosKit"),
        .target(name: "PuggleUpdate"),
        .testTarget(name: "PugglePhotosKitTests", dependencies: ["PugglePhotosKit"]),
        .testTarget(name: "PuggleUpdateTests", dependencies: ["PuggleUpdate"]),
    ]
)
