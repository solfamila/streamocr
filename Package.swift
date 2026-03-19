// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CaptureShellApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CaptureShellApp", targets: ["CaptureShellApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.99.0")
    ],
    targets: [
        .executableTarget(
            name: "CaptureShellApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "CaptureShellAppTests",
            dependencies: [
                "CaptureShellApp",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
