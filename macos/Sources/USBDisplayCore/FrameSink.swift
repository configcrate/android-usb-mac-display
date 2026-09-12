import Foundation

/// 传输层抽象：AOA Bulk / ADB 隧道 / 本地回环 都实现它。
/// 上层分帧与协议逻辑完全复用，便于在 AOA 不可用时快速切到兜底通道。
public protocol FrameSink: AnyObject {
    /// 阻塞写入，返回实际接受字节数。实现方需自带背压。
    @discardableResult
    func write(_ bytes: [UInt8]) -> Int
}

/// 接收回调，由传输层在独立线程调用。
public protocol FrameSourceDelegate: AnyObject {
    func frameSource(_ source: FrameSource, didReceive frame: ReceivedFrame)
    func frameSource(_ source: FrameSource, didFail error: Error)
}

public struct ReceivedFrame {
    public let header: FrameHeader
    public let payload: [UInt8]
}

public protocol FrameSource: AnyObject {
    var delegate: FrameSourceDelegate? { get set }
    func start()
    func stop()
}
