import Foundation
import IOKit
import IOKit.usb

/// AOA（Android Open Accessory）主机侧传输实现。
///
/// 流程（详见 protocol/aoa.h）：
///   1. 枚举 USB 设备，识别 Android 手机
///   2. GET_PROTOCOL 探测是否支持 AOA
///   3. SEND_STRING 发送 manufacturer/model/description/version/URI/serial
///   4. ACCESSORY_START 让手机重新枚举成 accessory
///   5. 在 accessory 设备上找到 class=0xFF sub=0xFF proto=0x00 的接口
///   6. 拿到 Bulk IN / Bulk OUT 端点，开始双向传输
///
/// ⚠️ 为什么不用 Isochronous：Iso 不保证送达，H.264 帧内一字节损坏即整帧报废，
/// 且 macOS 用户态对 Iso 支持薄弱。Bulk + 重传更合适（见 docs/02-architecture.md）。
public final class AOATransport: FrameSink, FrameSource {

    public struct DeviceInfo {
        public let vendorID: UInt16
        public let productID: UInt16
        public let manufacturer: String
        public let product: String
    }

    private let queue = DispatchQueue(label: "dev.configcrate.usbdisplay.usb", qos: .userInteractive)

    // 由 IOKit 拿到的句柄（真实实现中为 io_service_t / IOUSBHostDevice）
    private var deviceHandle: io_service_t = 0
    private var interfaceHandle: io_service_t = 0
    private var bulkInPipe: UInt8 = 0
    private var bulkOutPipe: UInt8 = 0

    /// 写队列：批量写比逐帧写吞吐高，且给上层提供背压
    private let writeQueue = DispatchQueue(label: "dev.configcrate.usbdisplay.usb.write",
                                           qos: .userInteractive)
    private var pendingWrites: [[UInt8]] = []
    private let writeLock = NSLock()
    private var writeThreadRunning = false

    public weak var delegate: FrameSourceDelegate?

    public private(set) var isConnected = false

    // MARK: - 设备发现

    /// 扫描当前连接的 Android 设备，返回首个候选。
    public static func findAndroidDevice() -> DeviceInfo? {
        // 真实实现：IOServiceMatching(kIOUSBDeviceClassName) + 逐个查 vendorID
        // 这里给出判断依据，避免把 iPhone / 键盘 / 网卡误识别
        //
        //   vendorID 集合：
        //     0x18D1 Google
        //     0x04E8 Samsung
        //     0x2717 Xiaomi
        //     0x2A70 OnePlus / OPPO
        //     0x12D1 Huawei
        //     0x22D9 vivo
        //     0x2D95 Meizu
        //     0x0BB4 HTC
        //     0x05C6 Qualcomm
        //     0x2E04 Honor
        //     0x0E8D MediaTek
        //     0x0FCE Sony
        //     0x1EBF ZTE
        return nil
    }

    public static let androidVendorIDs: Set<UInt16> = [
        0x18D1, 0x04E8, 0x2717, 0x2A70, 0x12D1, 0x22D9,
        0x2D95, 0x0BB4, 0x05C6, 0x2E04, 0x0E8D, 0x0FCE, 0x1EBF,
    ]

    // MARK: - AOA 握手

    public enum AOAError: LocalizedError {
        case noDevice
        case notSupported
        case handshakeFailed(String)
        case switchFailed
        case accessoryNotFound
        case endpointNotFound

        public var errorDescription: String? {
            switch self {
            case .noDevice: return "未找到 Android 设备"
            case .notSupported: return "设备不支持 AOA（可能是充电线或未开启 USB 调试）"
            case .handshakeFailed(let s): return "AOA 握手失败: \(s)"
            case .switchFailed: return "切换 accessory 模式失败"
            case .accessoryNotFound: return "切换后未找到 accessory 接口"
            case .endpointNotFound: return "未找到 Bulk 端点"
            }
        }
    }

    /// 执行完整 AOA 握手。成功后设备会以 VID=0x18D1 PID=0x2D00/0x2D01 重新枚举。
    public func handshake(appName: String = "USB Display",
                          onProgress: ((String) -> Void)? = nil) throws {
        guard let info = Self.findAndroidDevice() else {
            throw AOAError.noDevice
        }
        onProgress?("发现设备 \(info.manufacturer) \(info.product)")

        let support = try getProtocol(handle: deviceHandle)
        guard support >= 1 else { throw AOAError.notSupported }
        onProgress?("AOA 协议版本 v\(support)")

        try sendString(handle: deviceHandle, index: AOAString.manufacturer.rawValue,
                       value: "ConfigCrate")
        try sendString(handle: deviceHandle, index: AOAString.model.rawValue, value: appName)
        try sendString(handle: deviceHandle, index: AOAString.description.rawValue,
                       value: "USB Display Link")
        try sendString(handle: deviceHandle, index: AOAString.version.rawValue, value: "1.0")
        // URI 与 serial 用于 Android 侧 accessory_filter 精确匹配，避免和 Android Auto 抢设备
        try sendString(handle: deviceHandle, index: AOAString.uri.rawValue,
                       value: "https://github.com/ConfigCrate/android-usb-mac-display")
        try sendString(handle: deviceHandle, index: AOAString.serial.rawValue, value: "usbdisplay-0001")

        guard try startAccessory(handle: deviceHandle) else {
            throw AOAError.switchFailed
        }
        onProgress?("已切换到 accessory 模式，等待设备重新枚举...")

        // 等设备重新出现（典型 300ms ~ 2s）
        guard waitForAccessory(timeout: 5.0) else {
            throw AOAError.accessoryNotFound
        }
        try openBulkEndpoints()
        isConnected = true
    }

    /// AOA control request 编号，与 protocol/aoa.h 保持一致。
    private enum AOARequest: UInt8 {
        case getProtocol = 51
        case sendString = 52
        case accessoryStart = 53
    }

    private enum AOAString: UInt16 {
        case manufacturer = 0, model = 1, description = 2
        case version = 3, uri = 4, serial = 5
    }

    private func getProtocol(handle: io_service_t) throws -> Int {
        var value: UInt16 = 0
        let result = IOUSBDeviceRequest(
            handle: handle,
            requestType: 0xC0,          // IN | Vendor | Device
            request: AOARequest.getProtocol.rawValue,
            value: 0,
            index: 0,
            length: 2,
            data: &value
        )
        guard result == kIOReturnSuccess else {
            throw AOAError.handshakeFailed("GET_PROTOCOL 返回 0x\(String(result, radix: 16))")
        }
        return Int(value)
    }

    private func sendString(handle: io_service_t, index: UInt16, value: String) throws {
        var bytes = Array(value.utf8)
        // AOA 要求以 NUL 结尾，且长度必须包含 NUL
        bytes.append(0)
        let result = bytes.withUnsafeMutableBufferPointer { buf -> IOReturn in
            IOUSBDeviceRequest(
                handle: handle,
                requestType: 0x40,      // OUT | Vendor | Device
                request: AOARequest.sendString.rawValue,
                value: 0,
                index: index,
                length: UInt16(buf.count),
                data: buf.baseAddress
            )
        }
        guard result == kIOReturnSuccess else {
            throw AOAError.handshakeFailed("SEND_STRING[\(index)] 返回 0x\(String(result, radix: 16))")
        }
    }

    private func startAccessory(handle: io_service_t) throws -> Bool {
        let result = IOUSBDeviceRequest(
            handle: handle,
            requestType: 0x40,
            request: AOARequest.accessoryStart.rawValue,
            value: 0, index: 0, length: 0, data: nil
        )
        return result == kIOReturnSuccess
    }

    /// 等待 accessory 设备出现（VID 0x18D1，PID 0x2D00/0x2D01）。
    private func waitForAccessory(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 真实实现：IOServiceGetMatchingServices 轮询
            //   matching: { "idVendor": 0x18D1, "idProduct": 0x2D00 }
            // 或使用 IOKit notification port 事件驱动（更省 CPU）
            if let _ = Self.findAccessoryDevice() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    static func findAccessoryDevice() -> DeviceInfo? {
        // VID 0x18D1，PID 0x2D00(accessory) / 0x2D01(accessory+adb)
        return nil
    }

    private func openBulkEndpoints() throws {
        // 真实实现：
        //   1. 在 accessory 设备上找 interface class=0xFF sub=0xFF proto=0x00
        //   2. 遍历其 endpoint descriptors，找 kUSBEndpointTypeBulk：
        //        - direction kUSBIn  → bulkInPipe
        //        - direction kUSBOut → bulkOutPipe
        //   3. IOUSBHostInterface.Open / IOUSBHostPipe 打开
        //   4. 注册 AsyncIO 回调（读）与调度（写）
        //
        // 必须使用异步 IO（IOUSBHostPipe.AsyncIO 或 IOUSBInterfaceInterface 的
        // ReadPipeAsync/WritePipeAsync）。同步传输会在等待完成时占死线程，
        // 高帧率下必然掉帧。
    }

    // MARK: - FrameSink

    public func write(_ bytes: [UInt8]) {
        writeLock.lock()
        // 背压策略：若积压超过 8 MiB，丢弃最老的非关键帧批次。
        // 宁可丢帧也不能让延迟无限增长 —— 这是实时投屏的铁律。
        let queued = pendingWrites.reduce(0) { $0 + $1.count }
        if queued > 8 * 1024 * 1024 {
            let dropped = pendingWrites.count
            pendingWrites.removeAll(keepingCapacity: true)
            FileHandle.standardError.write(
                "USB backpressure: dropped \(dropped) buffers\n".data(using: .utf8)!)
        }
        pendingWrites.append(bytes)
        writeLock.unlock()
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            guard !self.pendingWrites.isEmpty else {
                self.writeThreadRunning = false
                self.writeLock.unlock()
                return
            }
            let batch = self.pendingWrites
            self.pendingWrites.removeAll(keepingCapacity: true)
            self.writeLock.unlock()

            for buffer in batch {
                self.rawWrite(buffer)
            }
        }
    }

    private func rawWrite(_ buffer: [UInt8]) {
        guard isConnected else { return }
        // 真实实现：IOUSBHostPipe.EnqueueIORequest / WritePipeAsync
        // 单次传输控制在 2 MiB 以内（USBD.maxTransfer），避免长时间独占总线。
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + USBD.maxTransfer, buffer.count)
            let chunk = Array(buffer[offset..<end])
            // submitAsyncWrite(chunk)   // ← 异步，不阻塞
            offset = end
        }
    }

    // MARK: - FrameSource

    public func start() {
        queue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// 读循环：从 Bulk IN 端点持续读，流式重组 FrameHeader + payload。
    ///
    /// 重组要点：一个逻辑帧可能跨多次 Bulk 读，必须按 payload_len 累加，
    /// 不能假设"一次 read = 一帧"。
    private func readLoop() {
        var accumulator: [UInt8] = []
        accumulator.reserveCapacity(64 * 1024)
        var pendingHeader: FrameHeader?
        var bytesNeeded = 0

        while isConnected {
            // let chunk = readBulk(bulkInPipe, maxLength: 64 * 1024)  // 真实实现
            let chunk: [UInt8] = []
            guard !chunk.isEmpty else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            accumulator.append(contentsOf: chunk)

            while true {
                if pendingHeader == nil {
                    guard accumulator.count >= USBD.headerSize else { break }
                    guard let header = FrameHeader.decode(accumulator[0...]) else {
                        // 头无效：丢弃一个字节重新同步（防止错位后永久卡死）
                        accumulator.removeFirst()
                        continue
                    }
                    pendingHeader = header
                    bytesNeeded = Int(header.payloadLength)
                    accumulator.removeFirst(USBD.headerSize)
                }

                guard let header = pendingHeader, accumulator.count >= bytesNeeded else { break }
                let payload = Array(accumulator[0..<bytesNeeded])
                accumulator.removeFirst(bytesNeeded)
                pendingHeader = nil
                bytesNeeded = 0

                let frame = ReceivedFrame(header: header, payload: payload)
                delegate?.frameSource(self, didReceive: frame)
            }

            // 防御：异常大的 payload_len 说明流已错位
            if bytesNeeded > 64 * 1024 * 1024 {
                pendingHeader = nil
                bytesNeeded = 0
                accumulator.removeAll(keepingCapacity: true)
            }
        }
    }

    public func stop() {
        isConnected = false
        writeLock.lock()
        pendingWrites.removeAll()
        writeLock.unlock()
    }
}

// MARK: - IOKit 薄封装（真实实现用 IOUSBHostDevice）

@discardableResult
private func IOUSBDeviceRequest(handle: io_service_t,
                                requestType: UInt8,
                                request: UInt8,
                                value: UInt16,
                                index: UInt16,
                                length: UInt16,
                                data: UnsafeMutableRawPointer?) -> IOReturn {
    // 真实实现：
    //   let device = IOUSBHostDevice(service: handle)
    //   var req = IOUSBHostDeviceRequest()
    //   req.bmRequestType = requestType
    //   req.bRequest = request
    //   req.wValue = value
    //   req.wIndex = index
    //   req.wLength = length
    //   try device.deviceRequest(&req, timeout: 1.0)
    return kIOReturnSuccess
}
