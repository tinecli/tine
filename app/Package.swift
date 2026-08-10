// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tine",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "tine", path: "Sources/tine"),
        .testTarget(name: "tineTests", path: "Tests/tineTests")
    ]
)
