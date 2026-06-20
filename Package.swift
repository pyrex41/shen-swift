// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShenSwift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "ShenSwift", targets: ["ShenSwift"]),
        .executable(name: "shen-swift", targets: ["shen-swift"]),
    ],
    targets: [
        .target(
            name: "ShenSwift",
            resources: [.copy("klambda")]
        ),
        .executableTarget(
            name: "shen-swift",
            dependencies: ["ShenSwift"]
        ),
        .testTarget(
            name: "ShenSwiftTests",
            dependencies: ["ShenSwift"]
        ),
    ]
)
