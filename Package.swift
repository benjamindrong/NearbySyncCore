// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NearbySyncCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .macCatalyst(.v17)
    ],
    products: [
        .library(
            name: "NearbySyncCore",
            targets: ["NearbySyncCore"]
        )
    ],
    targets: [
        .target(
            name: "NearbySyncCore"
        ),
        .testTarget(
            name: "NearbySyncCoreTests",
            dependencies: ["NearbySyncCore"]
        )
    ]
)
