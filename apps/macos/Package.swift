// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wadjet",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Wadjet", path: "Sources/Wadjet")
    ]
)
