import Foundation
import CoreGraphics
import USBDisplayCore

/// 命令行入口：`usbdisplayctl` —— 无 GUI，便于快速验证全链路延迟。
///
/// 用法：
///   usbdisplayctl probe                  探测设备与后端可用性
///   usbdisplayctl run [--width N] ...    启动投屏会话
///   usbdisplayctl doctor                 环境自检

struct Args {
    var command = "doctor"
    var width = 1920
    var height = 1080
    var fps = 60
    var bitrate = 12_000_000
    var backend = VirtualDisplayBackend.captureOnly
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "probe", "run", "doctor":
            args.command = a
        case "--width":    args.width = Int(it.next() ?? "") ?? args.width
        case "--height":   args.height = Int(it.next() ?? "") ?? args.height
        case "--fps":      args.fps = Int(it.next() ?? "") ?? args.fps
        case "--bitrate":  args.bitrate = Int(it.next() ?? "") ?? args.bitrate
        case "--backend":
            switch it.next() ?? "" {
            case "virtual": args.backend = .cgVirtualDisplay
            case "capture": args.backend = .captureOnly
            case "sck":     args.backend = .screenCaptureKit
            default: break
            }
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            break
        }
    }
    return args
}

func printUsage() {
    print("""
    usbdisplayctl — Mac 端 USB 副屏

    USAGE:
      usbdisplayctl <command> [options]

    COMMANDS:
      doctor    环境自检（推荐首次运行）
      probe     探测 Android 设备与 AOA 支持
      run       启动投屏会话

    OPTIONS:
      --width  N       视频宽度，默认 1920
      --height N       视频高度，默认 1080
      --fps    N       帧率，默认 60
      --bitrate N      码率 bps，默认 12000000
      --backend <name> capture | virtual | sck
                       capture = 采集主屏（默认，最稳）
                       virtual = CGVirtualDisplay 真副屏（私有 API）
    """)
}

func doctor() {
    print("== usbdisplayctl 环境自检 ==\n")

    let os = ProcessInfo.processInfo.operatingSystemVersion
    print("macOS 版本: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

    let hasVirtual = CGVirtualDisplayBackend.isAvailable
    print("CGVirtualDisplay 私有 API: \(hasVirtual ? "✅ 可用" : "❌ 不可用")")
    if hasVirtual {
        print("   → 可用 --backend virtual 体验真副屏")
    } else {
        print("   → 请使用默认 capture 模式（采集主屏）")
    }

    let displays = activeDisplays()
    print("当前显示器数量: \(displays.count)")
    for d in displays {
        let size = CGDisplayPixelsWide(d)
        let h = CGDisplayPixelsHigh(d)
        let hz = CGDisplayCopyDisplayMode(d)?.refreshRate ?? 0
        print("   displayID=\(d)  \(size)x\(h)@\(Int(hz))Hz")
    }

    if let dev = AOATransport.findAndroidDevice() {
        print("Android 设备: ✅ \(dev.manufacturer) \(dev.product)")
    } else {
        print("Android 设备: ⚠️ 未检测到（插上手机并确认已信任此电脑）")
    }

    print("\n常见问题：")
    print("  · 「未找到 Android 设备」→ 换一根**数据线**（很多线只能充电）")
    print("  · 「不支持 AOA」→ 部分厂商 ROM 移除了 AOA，可改用 ADB 隧道兜底")
    print("  · 延迟偏高 → 用 --fps 30 试，确认是否编码器帧率跟不上")
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func probe() {
    if let dev = AOATransport.findAndroidDevice() {
        print("找到设备: \(dev.manufacturer) \(dev.product)")
        print("  vendorID: 0x\(String(dev.vendorID, radix: 16))")
        print("  productID: 0x\(String(dev.productID, radix: 16))")
    } else {
        print("未找到 Android 设备")
    }
    print("CGVirtualDisplay 可用: \(CGVirtualDisplayBackend.isAvailable)")
}

// MARK: - main

let args = parseArgs()
switch args.command {
case "doctor":
    doctor()

case "probe":
    probe()

case "run":
    let options: DisplayLinkSession.Options = {
        let o = DisplayLinkSession.Options()
        var o2 = o
        o2.width = args.width
        o2.height = args.height
        o2.fps = args.fps
        o2.bitrateBps = args.bitrate
        o2.backend = args.backend
        return o2
    }()

    let session = DisplayLinkSession(options: options)

    // Ctrl-C 优雅退出，避免虚拟显示器残留
    signal(SIGINT) { _ in
        FileHandle.standardError.write("\n收到中断信号，正在退出...\n".data(using: .utf8)!)
        exit(0)
    }

    do {
        try session.start()
        session.run()
    } catch {
        FileHandle.standardError.write(
            "启动失败: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

default:
    printUsage()
}
