// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "USBDisplay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "USBDisplayCore", targets: ["USBDisplayCore"]),
        .executable(name: "usbdisplayctl", targets: ["usbdisplayctl"]),
    ],
    targets: [
        .target(
            name: "USBDisplayCore",
            path: "Sources/USBDisplayCore",
            swiftSettings: [
                // ScreenCaptureKit 的 SCStreamOutput 是 @objc 协议，需要与 ObjC 互操作
                .unsafeFlags(["-enable-experimental-feature", "StrictConcurrency"]),
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "usbdisplayctl",
            dependencies: ["USBDisplayCore"],
            path: "Sources/usbdisplayctl"
        ),
    ]
)
