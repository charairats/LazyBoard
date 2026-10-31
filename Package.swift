// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LazyBoard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LazyBoard",
            path: "Sources/LazyBoard"
        )
    ]
)
