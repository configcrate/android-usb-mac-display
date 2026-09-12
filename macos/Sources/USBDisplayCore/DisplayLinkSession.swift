import Foundation
import CoreVideo

/// 会话编排：把采集 → 编码 → 分帧 → USB 串起来，并处理反向输入与自适应码率。
///
/// 生命周期：
///   start()  → AOA 握手 → 采集/编码就绪 → 等 Android 报告 Surface 就绪 → 推首个 IDR
///   run()    → 帧循环 + 心跳 + 统计上报 + 码率自适应
///   stop()   → 冲刷编码器 → 释放虚拟显示器 → 关闭 USB
public final class DisplayLinkSession {

    public struct Options {
        public var width = 1920
        public var height = 1080
        public var fps = 60
        public var bitrateBps = 12_000_000
        public var backend: VirtualDisplayBackend = .screenCaptureKit
        /// 心跳间隔，用于 RTT 统计
        public var pingInterval: TimeInterval = 1.0
        /// 统计上报间隔，用于自适应码率
        public var statsInterval: TimeInterval = 0.5

        public init() {}
    }

    private let options: Options
    private let transport: AOATransport
    private let framer: FrameFramer
    private let encoder: H264Encoder
    private let injector: InputInjector
    private var display: VirtualDisplay?

    // 状态
    private var running = false
    private var seq: UInt32 = 0
    private var nextPingAt: Date = .distantPast
    private var nextStatsAt: Date = .distantPast
    private var lastPingSentUs: UInt32 = 0
    private var peerStats = PeerStats()
    private var localStats = PeerStats()
    /// Android 侧 Surface 就绪前不推帧，否则浪费带宽且首批帧全丢
    private var peerReady = false
    private var forceKeyframePending = true
    /// 配置 epoch：分辨率/帧率/编码器重建时自增，通知对端刷新解码器
    private var configEpoch: UInt32 = 0

    private let statsLock = NSLock()
    private var recentRttUs: [UInt32] = []

    public init(options: Options = Options()) {
        self.options = options
        self.transport = AOATransport()
        self.framer = FrameFramer(sink: transport)
        self.encoder = H264Encoder(config: H264Encoder.Config(
            width: options.width,
            height: options.height,
            fps: options.fps,
            bitrateBps: options.bitrateBps))
        self.injector = InputInjector(
            targetSize: CGSize(width: options.width, height: options.height))
    }

    // MARK: - 生命周期

    public func start() throws {
        log("开始 AOA 握手...")
        try transport.handshake(appName: "USB Display") { msg in
            self.log(msg)
        }
        transport.delegate = self
        transport.start()

        log("启动编码器 \(options.width)x\(options.height)@\(options.fps)")
        try encoder.start()
        encoder.onEncodedFrame = { [weak self] annexB, keyframe, tsUs in
            self?.onEncoded(annexB: annexB, keyframe: keyframe, captureTsUs: tsUs)
        }

        try setupVirtualDisplay()

        // 发送初始配置，Android 侧据此创建 MediaCodec
        framer.sendConfig(StreamConfig(
            epoch: configEpoch,
            width: UInt16(options.width),
            height: UInt16(options.height),
            fps: UInt16(options.fps),
            codec: .h264,
            bitrateBps: UInt32(options.bitrateBps)))

        running = true
        log("会话已启动，等待 Android 就绪...")
    }

    private func setupVirtualDisplay() throws {
        switch options.backend {
        case .screenCaptureKit, .captureOnly:
            // 不创建虚拟显示器，直接采集主屏；适合 v0.1 验证延迟
            let mainID = CGMainDisplayID()
            let params = VirtualDisplayParams(
                name: "Main Display Mirror",
                width: options.width,
                height: options.height,
                refreshRate: options.fps)
            let capturer = ScreenCapturer(displayID: mainID, params: params) { [weak self] pb, ts in
                self?.onCaptured(pixelBuffer: pb, timestampUs: ts)
            }
            try capturer.start()
            self.displayID = mainID
            self.capturer = capturer

        case .cgVirtualDisplay:
            guard CGVirtualDisplayBackend.isAvailable else {
                log("⚠️ CGVirtualDisplay 不可用，回退 ScreenCaptureKit")
                try setupVirtualDisplayWithFallback()
                return
            }
            let params = VirtualDisplayParams(
                name: "USB Display",
                width: options.width,
                height: options.height,
                refreshRate: options.fps)
            let vd = CGVirtualDisplayBackend(params: params)
            try vd.start { [weak self] pb, ts in
                self?.onCaptured(pixelBuffer: pb, timestampUs: ts)
            }
            self.display = vd
            self.displayID = vd.displayID
            log("虚拟显示器已创建，displayID=\(vd.displayID.map(String.init) ?? "nil")")
        }
    }

    private func setupVirtualDisplayWithFallback() throws {
        var fallbackOptions = options
        fallbackOptions.backend = .screenCaptureKit
        let mainID = CGMainDisplayID()
        let params = VirtualDisplayParams(width: options.width, height: options.height,
                                          refreshRate: options.fps)
        let capturer = ScreenCapturer(displayID: mainID, params: params) { [weak self] pb, ts in
            self?.onCaptured(pixelBuffer: pb, timestampUs: ts)
        }
        try capturer.start()
        self.displayID = mainID
        self.capturer = capturer
    }

    private var displayID: CGDirectDisplayID?
    private var capturer: ScreenCapturer?

    public func stop() {
        running = false
        capturer?.stop()
        display?.stop()
        encoder.drain()
        encoder.stop()
        transport.stop()
        log("会话已停止")
    }

    /// 主循环：只负责心跳与统计，帧处理在各自线程回调中进行。
    public func run() {
        while running {
            let now = Date()
            if now >= nextPingAt {
                nextPingAt = now.addingTimeInterval(options.pingInterval)
                let tsUs = UInt32(mach_absolute_time() / 1000)
                lastPingSentUs = tsUs
                framer.sendPing(timestampUs: tsUs)
            }
            if now >= nextStatsAt {
                nextStatsAt = now.addingTimeInterval(options.statsInterval)
                reportStatsAndAdapt()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - 帧管线

    private func onCaptured(pixelBuffer: CVPixelBuffer, timestampUs: UInt64) {
        guard running, peerReady else { return }
        let force = forceKeyframePending
        forceKeyframePending = false
        encoder.encode(pixelBuffer: pixelBuffer,
                       captureTimestampUs: timestampUs,
                       forceKeyframe: force)
    }

    private func onEncoded(annexB: [UInt8], keyframe: Bool, captureTsUs: UInt64) {
        guard running else { return }
        framer.sendVideo(annexB, keyframe: keyframe, timestampUs: captureTsUs)
        seq &+= 1
    }

    // MARK: - 自适应码率

    private func reportStatsAndAdapt() {
        statsLock.lock()
        localStats.encodeUs = encoder.encodeDurationP50
        let rtts = recentRttUs
        statsLock.unlock()

        if let p50 = percentile(rtts, 0.5) {
            localStats.rttUs = p50
            peerStats.rttUs = p50
        }
        framer.sendStats(localStats)

        // 自适应闭环（详见 docs/02-architecture.md）
        let q = peerStats.queueFrames
        let dropped = peerStats.droppedFrames
        var newBitrate = options.bitrateBps

        if q > 2 {
            // 解码积压 → 降 10%
            newBitrate = Int(Double(options.bitrateBps) * 0.9)
        } else if q == 0 && localStats.rttUs > 0 && localStats.rttUs < 3_000 {
            // 有富余 → 升 5%
            newBitrate = Int(Double(options.bitrateBps) * 1.05)
        }

        if dropped > 0 {
            // 出现丢帧 → 立刻降 20% 并请求关键帧
            newBitrate = Int(Double(options.bitrateBps) * 0.8)
            forceKeyframePending = true
        }

        newBitrate = max(1_000_000, min(newBitrate, 40_000_000))
        // 只有变化超过 5% 才真正下发，避免频繁抖动
        if abs(newBitrate - options.bitrateBps) > options.bitrateBps / 20 {
            optionsBitrate = newBitrate
            encoder.updateBitrate(newBitrate)
            log("码率自适应 → \(newBitrate / 1_000_000) Mbps")
        }
    }

    private var optionsBitrate: Int = 0

    private func percentile(_ values: [UInt32], _ p: Double) -> UInt32? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int(Double(sorted.count - 1) * p)
        return sorted[idx]
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[usbdisplay] \(message)\n".data(using: .utf8)!)
    }
}

// MARK: - 反向帧处理

extension DisplayLinkSession: FrameSourceDelegate {
    public func frameSource(_ source: FrameSource, didReceive frame: ReceivedFrame) {
        switch frame.header.type {
        case USBD.typeTouch:
            guard let touch = TouchEvent.decode(frame.payload) else { return }
            injector.handle(touch)

        case USBD.typeKey:
            // payload: [keycode:u16][down:u8][flags:u32]
            guard frame.payload.count >= 7 else { return }
            let code = readU16(frame.payload, 0)
            let down = frame.payload[2] != 0
            let flagsRaw = readU32(frame.payload, 3)
            injector.handleKey(code: CGKeyCode(code),
                               down: down,
                               flags: CGEventFlags(rawValue: UInt64(flagsRaw)))

        case USBD.typeRequestKeyframe:
            // 对端解码器就绪 / 丢帧后请求关键帧
            forceKeyframePending = true
            peerReady = true
            log("收到 REQUEST_KEYFRAME，下一帧强制 IDR")

        case USBD.typePong:
            guard frame.payload.count >= 4 else { return }
            let sentUs = readU32(frame.payload, 0)
            let nowUs = UInt32(mach_absolute_time() / 1000)
            let rtt = nowUs &- sentUs
            statsLock.lock()
            recentRttUs.append(rtt)
            if recentRttUs.count > 30 { recentRttUs.removeFirst() }
            statsLock.unlock()

        case USBD.typeStats:
            peerStats = PeerStats(payload: frame.payload)

        case USBD.typePing:
            // 回 PONG：原样带上对端时间戳 + 本端时间
            guard frame.payload.count >= 4 else { return }
            var payload = frame.payload
            var nowUs = UInt32(mach_absolute_time() / 1000).littleEndian
            withUnsafeBytes(of: &nowUs) { payload.append(contentsOf: $0) }
            let header = FrameHeader(type: USBD.typePong, seq: 0,
                                     payloadLength: UInt32(payload.count)).encode()
            transport.write(header + payload)

        default:
            break
        }
    }

    public func frameSource(_ source: FrameSource, didFail error: Error) {
        log("USB 传输错误: \(error.localizedDescription)")
        running = false
    }
}
