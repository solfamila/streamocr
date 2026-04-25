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
        .target(
            name: "TradingRuntimeBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("Imported/long"),
                .headerSearchPath("Imported/third_party/ibapi_client_legacy"),
                .headerSearchPath("Imported/nlohmann_json/single_include"),
                .define("TWS_ORDER_STATUS_PERMID_IS_INT", to: "1"),
                .define("TWS_NEEDS_DECIMAL_FUNCTIONS_SHIM", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("GameController")
            ]
        ),
        .executableTarget(
            name: "CaptureShellApp",
            dependencies: [
                "TradingRuntimeBridge"
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("GameController"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "CaptureShellAppTests",
            dependencies: [
                "CaptureShellApp",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)
