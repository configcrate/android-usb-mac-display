import Foundation
import CUSBDisplay

/// Whole-message synchronous writes off the UI thread; bounded I/O timeouts.
public final class AOATransport: FrameSink, FrameSource {
    public struct DeviceInfo {
        public let vendorID: UInt16
        public let productID: UInt16
        public let manufacturer: String
        public let product: String
    }
    public weak var delegate: FrameSourceDelegate?
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let readerGroup = DispatchGroup()
    private var connected = false
    private var readerStarted = false
    private let usb: OpaquePointer?
    public var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return connected
    }
    public init() { usb = cc_usb_create() }
    deinit { if let usb { cc_usb_destroy(usb) } }
    public static func findAndroidDevice() -> DeviceInfo? {
        var vid: UInt16 = 0, pid: UInt16 = 0
        guard cc_usb_probe(&vid, &pid) == 1 else { return nil }
        return DeviceInfo(vendorID: vid, productID: pid,
            manufacturer: String(format: "USB %04x", vid), product: String(format: "%04x", pid))
    }
    public struct USBError: LocalizedError {
        let code: Int32
        public var errorDescription: String? {
            "USB: \(String(cString: cc_usb_error(code))). Use a data cable, unlock the phone, allow USB accessories, and connect only one Android device. AOA does not require USB debugging."
        }
    }
    public func handshake(appName: String = "USB Display", onProgress: ((String) -> Void)? = nil) throws {
        guard let usb else { throw USBError(code: -99) }
        onProgress?("Opening USB device and switching to AOA…")
        let rc = cc_usb_open(usb)
        guard rc == 0 else { throw USBError(code: rc) }
        stateLock.lock(); connected = true; stateLock.unlock()
        onProgress?("AOA bulk endpoints connected")
    }
    @discardableResult
    public func write(_ bytes: [UInt8]) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        guard let usb, isConnected else { return 0 }
        var offset = 0
        var error: Int32 = 0
        bytes.withUnsafeBufferPointer { buffer in
            while offset < bytes.count && isConnected {
                var actual: Int32 = 0
                let rc = cc_usb_write(usb, buffer.baseAddress!.advanced(by: offset),
                    Int32(min(bytes.count - offset, USBD.maxTransfer)), &actual)
                offset += Int(actual)
                // Do not skip a partially transmitted message's tail.
                if rc != 0 || actual == 0 { error = rc == 0 ? -1 : rc; break }
            }
        }
        if error != 0 { fail(USBError(code: error)) }
        return offset
    }
    public func start() {
        stateLock.lock()
        guard connected, !readerStarted else { stateLock.unlock(); return }
        readerStarted = true; readerGroup.enter(); stateLock.unlock()
        DispatchQueue(label: "dev.configcrate.usbdisplay.read", qos: .userInteractive).async { self.readLoop() }
    }
    private func readLoop() {
        defer { stateLock.lock(); readerStarted = false; stateLock.unlock(); readerGroup.leave() }
        guard let usb else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let parser = FrameStreamParser()
        while isConnected {
            var actual: Int32 = 0
            let rc = chunk.withUnsafeMutableBufferPointer { cc_usb_read(usb, $0.baseAddress, Int32($0.count), &actual) }
            do {
                if actual > 0 {
                    for frame in try parser.append(Array(chunk.prefix(Int(actual)))) {
                        delegate?.frameSource(self, didReceive: frame)
                    }
                }
            } catch { fail(error); return }
            // A timeout may still contain useful partial bytes.
            if rc != 0 && rc != -7 { fail(USBError(code: rc)); return }
        }
    }
    private func fail(_ error: Error) {
        stateLock.lock(); let notify = connected; connected = false; stateLock.unlock()
        if let usb { cc_usb_close(usb) }
        if notify { delegate?.frameSource(self, didFail: error) }
    }
    public func stop() {
        stateLock.lock(); connected = false; stateLock.unlock()
        if let usb { cc_usb_close(usb) }
        _ = readerGroup.wait(timeout: .now() + 5)
    }
}
