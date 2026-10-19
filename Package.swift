// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .executable(name: "Orbit", targets: ["OrbitApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "OrbitCore",
            dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]
        ),
        .executableTarget(name: "OrbitApp", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
    ],
    swiftLanguageModes: [.v5]
)
