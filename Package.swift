// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodMouse",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PodMouseCore"),
        .executableTarget(name: "PodMouse", dependencies: ["PodMouseCore"]),
        .testTarget(name: "PodMouseCoreTests", dependencies: ["PodMouseCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
