// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Joy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Joy", targets: ["Joy"])
    ],
    targets: [
        .executableTarget(
            name: "Joy",
            path: "Sources/Joy"
        ),
        .testTarget(
            name: "JoyTests",
            dependencies: ["Joy"],
            path: "Tests/JoyTests"
        ),
    ]
)
