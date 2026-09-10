// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macord",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Macord", targets: ["Macord"])
    ],
    targets: [
        .executableTarget(
            name: "Macord",
            path: "macos/Sources/Macord"
        )
    ]
)
