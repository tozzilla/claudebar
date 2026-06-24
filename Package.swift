// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TachyBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TachyBar",
            path: "Sources/TachyBar"
        )
    ]
)
