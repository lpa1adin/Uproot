// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Uproot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Uproot", path: "Sources/Uproot"),
        .testTarget(name: "UprootTests", dependencies: ["Uproot"], path: "Tests/UprootTests")
    ],
    swiftLanguageModes: [.v5]
)
