// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirTouch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AirTouch", targets: ["AirTouchApp"])],
    targets: [
        .target(name: "AirTouchCore"),
        .executableTarget(name: "AirTouchApp", dependencies: ["AirTouchCore"]),
        .testTarget(name: "AirTouchCoreTests", dependencies: ["AirTouchCore"])
    ],
    swiftLanguageModes: [.v5]
)
