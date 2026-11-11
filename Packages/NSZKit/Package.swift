// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NSZKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NSZKit", targets: ["NSZKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")
    ],
    targets: [
        .target(
            name: "NSZKit",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .testTarget(name: "NSZKitTests", dependencies: ["NSZKit"])
    ]
)
