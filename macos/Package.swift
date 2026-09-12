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
        .systemLibrary(name: "CLibusb", pkgConfig: "libusb-1.0", providers: [.brew(["libusb"])]),
        .target(name: "CUSBDisplay", dependencies: ["CLibusb"],
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
        .target(
            name: "USBDisplayCore",
            dependencies: ["CUSBDisplay"],
            path: "Sources/USBDisplayCore",
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
        .testTarget(name: "USBDisplayCoreTests", dependencies: ["USBDisplayCore"]),
    ]
)
