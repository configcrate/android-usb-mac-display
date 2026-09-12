import CoreGraphics
import CoreVideo
import Foundation
import CUSBDisplay
public enum VirtualDisplayBackend { case screenCaptureKit, cgVirtualDisplay, captureOnly }
public struct VirtualDisplayParams {
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Int
    public var sizeMillimeters: CGSize
    public var hiDPI: Bool
    public init(name: String = "USB Display", width: Int = 1920, height: Int = 1080,
        refreshRate: Int = 60, sizeMillimeters: CGSize = CGSize(width: 345,height: 195), hiDPI: Bool = false) {
        self.name = name; self.width = width; self.height = height
        self.refreshRate = refreshRate; self.sizeMillimeters = sizeMillimeters; self.hiDPI = hiDPI
    }
}
public protocol VirtualDisplay: AnyObject {
    var displayID: CGDirectDisplayID? { get }
    var params: VirtualDisplayParams { get }
    func start(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) throws
    func stop()
}
public final class CGVirtualDisplayBackend: VirtualDisplay {
    public let params: VirtualDisplayParams
    public private(set) var displayID: CGDirectDisplayID?
    private var handle: UnsafeMutableRawPointer?
    private var capturer: ScreenCapturer?
    public static var isAvailable: Bool { cc_virtual_available() != 0 }
    public init(params: VirtualDisplayParams) { self.params = params }
    public func start(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) throws {
        guard Self.isAvailable else { throw DisplayError.privateAPIAvailable }
        var id: UInt32 = 0
        var message = [CChar](repeating: 0, count: 512)
        handle = params.name.withCString {
            cc_virtual_create($0, UInt32(params.width), UInt32(params.height),
                Double(params.refreshRate), &id, &message, Int32(message.count))
        }
        guard handle != nil, id != 0 else { throw DisplayError.virtualCreation(String(cString: message)) }
        displayID = id
        Thread.sleep(forTimeInterval: 0.3)
        let capture = ScreenCapturer(displayID: id, params: params, onFrame: onFrame)
        capturer = capture
        do { try capture.start() } catch { stop(); throw error }
    }
    public func stop() {
        capturer?.stop(); capturer = nil
        if let handle { cc_virtual_destroy(handle) }
        handle = nil; displayID = nil
    }
    deinit { stop() }
}
public enum DisplayError: LocalizedError {
    case privateAPIAvailable, creationFailed, noDisplayID, captureUnavailable
    case virtualCreation(String)
    public var errorDescription: String? {
        switch self {
        case .privateAPIAvailable: return "Virtual display API unavailable; explicitly use --backend capture."
        case .virtualCreation(let s): return "Virtual display failed: \(s)"
        case .creationFailed: return "Virtual display creation failed"
        case .noDisplayID: return "No virtual display ID"
        case .captureUnavailable: return "Display unavailable. Allow Screen Recording for your terminal, then restart it."
        }
    }
}
