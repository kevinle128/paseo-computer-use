// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaseoComputerUse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PaseoComputerUseCore",
            targets: ["PaseoComputerUseCore"]
        ),
        .executable(
            name: "paseo-computer-use-helper",
            targets: ["PaseoComputerUseHelper"]
        ),
    ],
    targets: [
        .target(
            name: "PaseoComputerUseCore",
            path: "Sources/PaseoComputerUseCore"
        ),
        .executableTarget(
            name: "PaseoComputerUseHelper",
            dependencies: ["PaseoComputerUseCore"],
            path: "Sources/PaseoComputerUseHelper"
        ),
        .testTarget(
            name: "PaseoComputerUseTests",
            dependencies: ["PaseoComputerUseCore"],
            path: "Tests/PaseoComputerUseTests"
        ),
    ]
)
