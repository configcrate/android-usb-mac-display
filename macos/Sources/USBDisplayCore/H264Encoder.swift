import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox 硬件 H.264 编码器，为**低延迟实时投屏**调优。
///
/// 延迟关键配置（顺序有讲究）：
///  1. RealTime = true           → 进入实时码控路径
///  2. AllowFrameReordering=false→ 禁 B 帧，消除重排序延迟（省 1 帧 ≈ 16ms）
///  3. MaxFrameDelayCount = 1    → 编码器不允许攒帧
///  4. EnableLowLatencyRateControl → macOS 12+，VBV 缓冲压到最小
///  5. 输出 AVCC，由本类转 Annex-B  → MediaCodec 侧可直接喂流
public final class H264Encoder {

    public struct Config {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrateBps: Int

        public init(width: Int, height: Int, fps: Int = 60, bitrateBps: Int = 12_000_000) {
            self.width = width; self.height = height
            self.fps = fps; self.bitrateBps = bitrateBps
        }
    }

    public private(set) var config: Config
    private var session: VTCompressionSession?

    /// 输出：Annex-B 字节流 + 是否关键帧 + 采集时间戳
    public var onEncodedFrame: ((_ annexB: [UInt8], _ keyframe: Bool, _ captureTimestampUs: UInt64) -> Void)?

    /// 编码耗时环形统计（微秒），用于 STATS 上报
    private var encodeDurations: [UInt32] = []
    private let durationLock = NSLock()

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        var sessionOut: VTCompressionSession?

        // 采用 Swift 桥接的 block 版创建 API（VTCompressionSessionCreate 的
        // outputHandler 重载）。回调在 VideoToolbox 内部编码线程触发。
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                // 优先硬件编码器；某机型无硬编时允许回退，避免启动即失败
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                // IOSurface 背衬：采集侧输出的 CVPixelBuffer 可直接零拷贝传入
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            compressionSessionOut: &sessionOut,
            outputHandler: { [weak self] _, sampleBuffer, _ in
                self?.handleEncoded(sampleBuffer)
            }
        )
        guard status == noErr, let session = sessionOut else {
            throw EncoderError.creationFailed(status)
        }
        session_configure(session)
        self.session = session
    }

    private func session_configure(_ session: VTCompressionSession) {
        setProp(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProp(session, kVTCompressionPropertyKey_ProfileLevel,
                kVTProfileLevel_H264_High_AutoLevel)
        setProp(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        setProp(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 1 as CFNumber)
        setProp(session, kVTCompressionPropertyKey_AverageBitRate, config.bitrateBps as CFNumber)
        setProp(session, kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber)
        setProp(session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                (config.fps * 2) as CFNumber)
        setProp(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)

        if #available(macOS 12.0, *) {
            // 低延迟码控：把 VBV 缓冲最小化，牺牲码率平稳换延迟
            setProp(session, kVTCompressionPropertyKey_EnableLowLatencyRateControl,
                    kCFBooleanTrue)
        }

        // H.264 需要显式允许"帧内刷新"，配合低延迟码控
        setProp(session, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse)
    }

    private func setProp(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            // 部分属性在旧系统/特定硬件上不支持，记录后继续
            FileHandle.standardError.write(
                "VTSessionSetProperty \(key) failed: \(status)\n".data(using: .utf8)!)
        }
    }

    /// 动态调整码率（自适应闭环），无需重建 session。
    public func updateBitrate(_ bps: Int) {
        guard let session else { return }
        config.bitrateBps = bps
        // 低延迟码控下需要同时更新 DataRateLimits 才生效
        let bytesPerSecond = bps / 8
        let limits: [CFNumber] = [bytesPerSecond as CFNumber, 1 as CFNumber]
        setProp(session, kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        setProp(session, kVTCompressionPropertyKey_DataRateLimits, limits as CFArray)
    }

    /// 编码一帧。`forceKeyframe` 用于响应 Android 的 REQUEST_KEYFRAME。
    ///
    /// 调用来自采集线程（userInteractive QoS），必须**非阻塞**：
    /// VTCompressionSessionEncodeFrame 只做提交，真正的编码在 VT 内部线程，
    /// 结果经 outputHandler 回来。这里绝不做 CPU 拷贝或等待。
    public func encode(pixelBuffer: CVPixelBuffer,
                       captureTimestampUs: UInt64,
                       forceKeyframe: Bool = false) {
        guard let session else { return }
        // PTS 用采集时刻，端到端延迟统计才有意义（不要用 wall clock）
        let pts = CMTime(value: CMTimeValue(captureTimestampUs), timescale: 1_000_000)
        var frameProps: [CFString: Any] = [:]
        if forceKeyframe {
            frameProps[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue as Any
        }

        // refcon 把采集时间戳透传给输出回调，用于算"采集→编码完成"耗时
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(captureTimestampUs))

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: CMTimeValue(1_000_000 / max(config.fps, 1)),
                             timescale: 1_000_000),
            frameProperties: frameProps.isEmpty ? nil : frameProps as CFDictionary,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )

        if status == kVTInvalidSessionErr {
            // 硬件编解码器可能被系统抢占（如切换外接显示器），尝试重建
            FileHandle.standardError.write("VT session invalid, needs restart\n".data(using: .utf8)!)
        } else if status != noErr {
            FileHandle.standardError.write(
                "encode frame failed: \(status)\n".data(using: .utf8)!)
        }
    }

    /// 冲刷编码器，把缓冲中的帧逼出来（停止投屏时调用）。
    public func drain() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func stop() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - 输出回调（由 VT 在编码完成时调用）

    /// VideoToolbox 编码完成回调（内部编码线程）。
    /// 职责：AVCC → Annex-B，关键帧前置 SPS/PPS，然后交给 FrameFramer。
    fileprivate func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { return }

        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let avcc = Array(UnsafeBufferPointer(start: raw, count: length))

        var annexB: [UInt8] = []
        annexB.reserveCapacity(length + 32)

        // 关键帧必须把 SPS/PPS 前置，否则 Android 端 MediaCodec 无法初始化
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSets(from: fmt, to: &annexB)
        }
        annexB.append(contentsOf: avccToAnnexB(avcc))

        // PTS 即采集时刻（见 encode()），用它作为捕获时间戳
        let tsNum = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureTsUs = UInt64(max(0, CMTimeGetSeconds(tsNum)) * 1_000_000)

        // 统计"进入编码器 → 编码完成"的耗时，用于 STATS 上报
        let nowUs = UInt64(mach_absolute_time() / 1000)
        recordDuration(UInt32(min(nowUs &- captureTsUs, UInt64(UInt32.max))))

        onEncodedFrame?(annexB, keyframe, captureTsUs)
    }

    /// 从 CMFormatDescription 取出 SPS/PPS，写成 Annex-B。
    private func appendParameterSets(from format: CMFormatDescription, to out: inout [UInt8]) {
        var count = 0
        var nalLength: Int32 = 0
        // 先探测参数集数量
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
        guard status == noErr, count > 0 else { return }

        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let p = ptr, size > 0 else { continue }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(contentsOf: UnsafeBufferPointer(start: p, count: size))
        }
    }

    /// AVCC（4 字节大端长度前缀）→ Annex-B（00 00 00 01 start code）。
    /// MediaCodec 直接吃 Annex-B 最省事，无需自己拆 NAL 打 CODEC_CONFIG 标记。
    private func avccToAnnexB(_ avcc: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(avcc.count + 32)
        var i = 0
        while i + 4 <= avcc.count {
            let nalLen = (Int(avcc[i]) << 24) | (Int(avcc[i + 1]) << 16)
                | (Int(avcc[i + 2]) << 8) | Int(avcc[i + 3])
            i += 4
            guard nalLen > 0, i + nalLen <= avcc.count else { break }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(contentsOf: avcc[i..<(i + nalLen)])
            i += nalLen
        }
        return out
    }

    private func recordDuration(_ us: UInt32) {
        durationLock.lock()
        encodeDurations.append(us)
        if encodeDurations.count > 120 { encodeDurations.removeFirst() }
        durationLock.unlock()
    }

    public var encodeDurationP50: UInt32 {
        durationLock.lock()
        defer { durationLock.unlock() }
        guard !encodeDurations.isEmpty else { return 0 }
        return encodeDurations.sorted()[encodeDurations.count / 2]
    }
}

public enum EncoderError: LocalizedError {
    case creationFailed(OSStatus)
    public var errorDescription: String? {
        if case .creationFailed(let s) = self {
            return "VTCompressionSession 创建失败, OSStatus=\(s)"
        }
        return nil
    }
}
