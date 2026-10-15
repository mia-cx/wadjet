// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WadjetPrototype",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "WadjetPrototype", path: "Sources/WadjetPrototype")
    ]
)
