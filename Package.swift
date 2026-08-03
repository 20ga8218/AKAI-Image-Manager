// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AKAIImageManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AKAIImageManager", targets: ["AKAIImageManager"])
    ],
    targets: [
        .executableTarget(
            name: "AKAIImageManager",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "AKAIImageManagerTests",
            dependencies: ["AKAIImageManager"],
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
