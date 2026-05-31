// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blob",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Blob",
            path: "Sources/Blob"
        )
    ]
)
