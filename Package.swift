// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Torti",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Torti",
            path: "Sources/Torti"
        )
    ]
)
