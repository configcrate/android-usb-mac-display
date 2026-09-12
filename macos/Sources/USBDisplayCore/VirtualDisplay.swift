import CoreGraphics
import Foundation

/// 虚拟显示器抽象。
///
/// 三种实现策略（详见 docs/03-macos-virtual-display.md）：
///  - `.screenCaptureKit` 公开 API，采集现有屏幕/窗口，零安装摩擦，用于 v0.1 验证延迟
///  - `.cgVirtualDisplay`  私有 CGVirtualDisplay（10.15+），做出"真副屏"，用于 v0.2
///  - `.captureOnly`       仅采集，不改变系统显示器拓扑
public enum VirtualDisplayBackend {
    case screenCaptureKit
    case cgVirtualDisplay
    case captureOnly
}

public struct VirtualDisplayParams {
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    /// 物理尺寸（毫米），决定系统推断出的 DPI。345x195mm ≈ 15.6" 16:9。
    public var sizeMillimeters: CGSize
    public var hiDPI: Bool

    public init(name: String = "USB Display",
                width: Int = 1920,
                height: Int = 1080,
                refreshRate: Int = 60,
                sizeMillimeters: CGSize = CGSize(width: 345, height: 195),
                hiDPI: Bool = false) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.sizeMillimeters = sizeMillimeters
        self.hiDPI = hiDPI
    }

    public var pixelSize: Int { width * height * 4 } // BGRA
}

public protocol VirtualDisplay: AnyObject {
    var displayID: CGDirectDisplayID? { get }
    var params: VirtualDisplayParams { get }
    /// 开始把画面帧回调出去（CVPixelBuffer，由调用方管理生命周期）
    func start(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) throws
    func stop()
}

// MARK: - CGVirtualDisplay 实现（私有 API）

/// ⚠️ 使用 CoreGraphics 私有类 `CGVirtualDisplay`。
/// - 无法上架 App Store，仅适合自用/内部分发。
/// - 类名与选择子在 macOS 10.15 → 15.x 基本稳定，但 Apple 无任何兼容承诺。
/// - 若 `objc_getClass` 返回 nil，说明该版本已移除，应回退到 ScreenCaptureKit。
public final class CGVirtualDisplayBackend: VirtualDisplay {

    public let params: VirtualDisplayParams
    public private(set) var displayID: CGDirectDisplayID?

    private var descriptor: NSObject?
    private var display: NSObject?
    private var settings: NSObject?

    // 用 NSSelectorFromString 动态查找，避免编译期依赖私有头文件
    private let selInitWithDescriptor = NSSelectorFromString("initWithDescriptor:")
    private let selApplySettings = NSSelectorFromString("applySettings:")
    private let selDisplayID = NSSelectorFromString("displayID")

    public init(params: VirtualDisplayParams) {
        self.params = params
    }

    /// 运行时探测私有 API 是否可用。
    public static var isAvailable: Bool {
        objc_getClass("CGVirtualDisplay") != nil
            && objc_getClass("CGVirtualDisplayDescriptor") != nil
            && objc_getClass("CGVirtualDisplaySettings") != nil
            && objc_getClass("CGVirtualDisplayMode") != nil
    }

    public func start(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) throws {
        guard Self.isAvailable else {
            throw DisplayError.privateAPIAvailable
        }
        guard let descriptorClass = objc_getClass("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = objc_getClass("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = objc_getClass("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = objc_getClass("CGVirtualDisplayMode") as? NSObject.Type
        else {
            throw DisplayError.privateAPIAvailable
        }

        // --- Descriptor ---
        let desc = descriptorClass.init()
        setProperty(desc, "name", params.name)
        setProperty(desc, "maxPixelsWide", params.width)
        setProperty(desc, "maxPixelsHigh", params.height)
        setProperty(desc, "sizeInMillimeters", params.sizeMillimeters)
        setProperty(desc, "queue", DispatchQueue.main)
        // 虚拟显示器被系统回收时的回调，仅打日志
        let termination: @convention(block) (AnyObject, Int) -> Void = { _, reason in
            FileHandle.standardError.write(
                "virtual display terminated, reason=\(reason)\n".data(using: .utf8)!)
        }
        setProperty(desc, "terminationHandler", termination)
        descriptor = desc

        // --- Display ---
        guard displayClass.responds(to: selInitWithDescriptor) else {
            throw DisplayError.privateAPIAvailable
        }
        let unmanaged = displayClass.perform(selInitWithDescriptor, with: desc)
        guard let disp = unmanaged?.takeUnretainedValue() else {
            throw DisplayError.creationFailed
        }
        display = disp

        // --- Modes & Settings ---
        guard modeClass.responds(to: selInitWithDescriptor) else {
            throw DisplayError.privateAPIAvailable
        }
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard modeClass.responds(to: modeSel) else {
            throw DisplayError.privateAPIAvailable
        }
        // perform(_:with:with:with:) 只能传对象，这里用 NSInvocation 风格拆成两步
        let mode = makeMode(modeClass: modeClass,
                            selector: modeSel,
                            width: params.width,
                            height: params.height,
                            refreshRate: params.refreshRate)

        let s = settingsClass.init()
        setProperty(s, "hiDPI", params.hiDPI ? 1 : 0)
        setProperty(s, "modes", [mode])
        settings = s

        guard disp.responds(to: selApplySettings) else {
            throw DisplayError.privateAPIAvailable
        }
        _ = disp.perform(selApplySettings, with: s)

        // 取 displayID，供后续采集使用
        if disp.responds(to: selDisplayID) {
            let v = disp.perform(selDisplayID)?.takeUnretainedValue()
            displayID = (v as? NSNumber)?.uint32Value
        } else {
            displayID = nil
        }

        // 注意：虚拟显示器本身不产帧，画面仍需通过 ScreenCaptureKit / CGDisplayStream
        // 从 displayID 采集。这里把 onFrame 交给采集器（见 ScreenCapturer）。
        guard let id = displayID else { throw DisplayError.noDisplayID }
        let capturer = ScreenCapturer(displayID: id, params: params, onFrame: onFrame)
        self.capturer = capturer
        try capturer.start()
    }

    private var capturer: ScreenCapturer?

    public func stop() {
        capturer?.stop()
        capturer = nil
        if let settings, let display, display.responds(to: selApplySettings) {
            // 传入空 modes 释放显示器
            setProperty(settings, "modes", [])
            _ = display.perform(selApplySettings, with: settings)
        }
        display = nil
        descriptor = nil
        settings = nil
        displayID = nil
    }

    // MARK: helpers

    private func makeMode(modeClass: NSObject.Type, selector: Selector,
                          width: Int, height: Int, refreshRate: Int) -> NSObject {
        // NSInvocation 在 Swift 中不可用，退而用 objc_msgSend 的 typed 函数指针。
        typealias InitFn = @convention(c) (AnyObject, Selector, Int, Int, Int) -> AnyObject
        let imp = modeClass.method(for: selector)
        let fn = unsafeBitCast(imp, to: InitFn.self)
        return fn(modeClass, selector, width, height, refreshRate)
    }

    private func setProperty(_ object: NSObject, _ name: String, _ value: Any) {
        let sel = NSSelectorFromString("set\(name.prefix(1).uppercased())\(name.dropFirst()):")
        guard object.responds(to: sel) else {
            // 属性名不匹配通常是 macOS 版本差异，记录但不致命
            FileHandle.standardError.write(
                "CGVirtualDisplay: missing setter for \(name)\n".data(using: .utf8)!)
            return
        }
        object.perform(sel, with: value)
    }
}

public enum DisplayError: LocalizedError {
    case privateAPIAvailable
    case creationFailed
    case noDisplayID
    case captureUnavailable

    public var errorDescription: String? {
        switch self {
        case .privateAPIAvailable:
            return "CGVirtualDisplay 私有 API 不可用，请改用 ScreenCaptureKit 后端"
        case .creationFailed:
            return "虚拟显示器创建失败"
        case .noDisplayID:
            return "虚拟显示器未返回 displayID"
        case .captureUnavailable:
            return "屏幕采集不可用"
        }
    }
}
