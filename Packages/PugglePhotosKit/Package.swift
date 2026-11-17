// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PugglePhotosKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PugglePhotosKit", targets: ["PugglePhotosKit"]),
    ],
    targets: [
        .target(name: "PugglePhotosKit"),
        .testTarget(name: "PugglePhotosKitTests", dependencies: ["PugglePhotosKit"]),
    ]
)
