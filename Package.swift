// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Distiller",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DistillerCore", targets: ["DistillerCore"]),
        .library(name: "DistillerCommunity", targets: ["DistillerCommunity"]),
        .executable(name: "distiller", targets: ["distiller-cli"]),
        .executable(name: "DistillerApp", targets: ["DistillerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "DistillerCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .target(
            name: "DistillerCommunity",
            dependencies: ["DistillerCore", .product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "distiller-cli",
            dependencies: [
                "DistillerCore",
                "DistillerCommunity",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "DistillerApp",
            dependencies: ["DistillerCore", "DistillerCommunity"]
        ),
        .testTarget(
            name: "DistillerCoreTests",
            dependencies: ["DistillerCore", "DistillerCommunity"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
