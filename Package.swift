// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VantaShot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VantaShot", targets: ["VantaShot"])
    ],
    targets: [
        .target(name: "VantaShotCore"),
        .target(name: "VantaShotRendering", dependencies: ["VantaShotCore"]),
        .testTarget(name: "VantaShotAppTests", dependencies: ["VantaShot"]),
        .testTarget(name: "VantaShotCoreTests", dependencies: ["VantaShotCore"]),
        .testTarget(name: "VantaShotRenderingTests", dependencies: ["VantaShotRendering", "VantaShotCore"]),
        .executableTarget(
            name: "VantaShot",
            dependencies: ["VantaShotCore", "VantaShotRendering"],
            path: "Sources/VantaShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
