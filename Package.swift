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
    targets: [
        .executableTarget(
            name: "CaptureShellApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
