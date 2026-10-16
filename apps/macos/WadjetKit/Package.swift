// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WadjetKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WadjetKit", targets: ["WadjetKit"])],
    targets: [
        .target(name: "WadjetKit"),
        .testTarget(name: "WadjetKitTests", dependencies: ["WadjetKit"]),
    ]
)
