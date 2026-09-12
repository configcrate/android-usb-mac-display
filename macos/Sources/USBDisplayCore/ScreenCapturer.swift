import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 把某个 display 的画面以 CVPixelBuffer 形式回调出来。
///
/// 优先 ScreenCaptureKit（公开 API、输出 IOSurface 支撑的 CVPixelBuffer，
/// 可直接零拷贝喂 VideoToolbox）。macOS 12.3 以下回退 CGDisplayStream。
///
/// 刻意避免 CGWindowListCreateImage / CGDisplayCreateImage：
/// 二者是同步全屏抓取，单帧常超过 20ms，会直接击穿延迟预算。
public final class ScreenCapturer: NSObject {

    private let displayID: CGDirectDisplayID
    private let params: VirtualDisplayParams
    private let onFrame: (CVPixelBuffer, UInt64) -> Void

    private var stream: SCStream?
    private var displayStream: CGDisplayStream?
    private var frameIndex: UInt64 = 0

    public init(displayID: CGDirectDisplayID,
                params: VirtualDisplayParams,
                onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) {
        self.displayID = displayID
        self.params = params
        self.onFrame = onFrame
    }

    public func start() throws {
        if #available(macOS 12.3, *) {
            try startScreenCaptureKit()
        } else {
            try startCGDisplayStream()
        }
    }

    public func stop() {
        if let stream {
            stream.stopCapture { _ in }
        }
        stream = nil
        displayStream?.stop()
        displayStream = nil
    }

    // MARK: - ScreenCaptureKit

    @available(macOS 12.3, *)
    private func startScreenCaptureKit() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedDisplay: SCDisplay?
        var capturedError: Error?

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            defer { semaphore.signal() }
            if let error { capturedError = error; return }
            capturedDisplay = content?.displays.first { $0.displayID == self.displayID }
            if capturedDisplay == nil {
                capturedError = DisplayError.captureUnavailable
            }
        }
        semaphore.wait()

        if let capturedError { throw capturedError }
        guard let display = capturedDisplay else { throw DisplayError.captureUnavailable }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = params.width
        config.height = params.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(params.refreshRate))
        // BGRA 是 VideoToolbox 硬编支持最好的格式
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = true
        // 队列深度压到 3：越浅延迟越低
        config.queueDepth = 3
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream

        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        stream.startCapture { error in
            startError = error
            startSemaphore.signal()
        }
        startSemaphore.wait()
        if let startError { throw startError }
    }

    private lazy var captureQueue: DispatchQueue = {
        // 用户交互优先级，保证采集不被后台任务饿死
        DispatchQueue(label: "dev.configcrate.usbdisplay.capture", qos: .userInteractive)
    }()

    // MARK: - CGDisplayStream（macOS 12.3 以下回退）

    private func startCGDisplayStream() throws {
        let props: [String: Any] = [
            CGDisplayStream.frameQueue: captureQueue,
            CGDisplayStream.preserveAspectRatio: kCFBooleanTrue as Any,
            CGDisplayStream.showCursor: kCFBooleanTrue as Any,
            CGDisplayStream.minimumFrameTime: CMTime(value: 1,
                                                     timescale: CMTimeScale(params.refreshRate)),
        ]
        guard let ds = CGDisplayStream(display: displayID,
                                       outputWidth: params.width,
                                       outputHeight: params.height,
                                       pixelFormat: kCVPixelFormatType_32BGRA,
                                       properties: props,
                                       queue: captureQueue) { [weak self] status, _, surface, _ in
            guard let self, status == .frameComplete, let surface else { return }
            self.emit(surface: surface)
        } else {
            throw DisplayError.captureUnavailable
        }
        displayStream = ds
        // CGDisplayStream 的同步启动结果由首个回调 status != .frameComplete 表达
        if ds.start() != .success {
            throw DisplayError.captureUnavailable
        }
    }

    private func emit(surface: IOSurface) {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return }
        frameIndex &+= 1
        // 时间戳用 mach absolute time 转微秒，避免和墙钟抖动耦合
        let timestampUs = UInt64(mach_absolute_time() / 1000)
        onFrame(pixelBuffer, timestampUs)
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension ScreenCapturer: SCStreamOutput {
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        // .screen 类型的 sampleBuffer 可能携带"无新帧"标记
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let statusRaw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameIndex &+= 1
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = UInt64(max(0, CMTimeGetSeconds(ts)) * 1_000_000)
        onFrame(pixelBuffer, timestampUs)
    }
}

// MARK: - SCStreamDelegate

@available(macOS 12.3, *)
extension ScreenCapturer: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "ScreenCaptureKit stopped: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}
