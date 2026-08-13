// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "touchutil",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "touchutil",
            path: "Sources/touchutil"
        ),
        .testTarget(
            name: "touchutilTests",
            dependencies: ["touchutil"]
        )
    ]
)
