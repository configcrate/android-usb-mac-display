import Foundation

// MARK: - 常量（必须与 protocol/frame.h 严格一致）

public enum USBD {
    public static let version: UInt8 = 1
    public static let headerSize = 16
    public static let maxTransfer = 2 * 1024 * 1024

    public static let typeVideo: UInt8 = 0x01
    public static let typeConfig: UInt8 = 0x02
    public static let typeTouch: UInt8 = 0x10
    public static let typeKey: UInt8 = 0x11
    public static let typePing: UInt8 = 0x20
    public static let typePong: UInt8 = 0x21
    public static let typeRequestKeyframe: UInt8 = 0x30
    public static let typeStats: UInt8 = 0x40

    public static let flagKeyframe: UInt16 = 0x0001
    public static let flagConfigEpochChanged: UInt16 = 0x0002

    public static let magic: [UInt8] = [0x55, 0x53, 0x42, 0x44] // "USBD"
}

public enum TouchAction: UInt8 {
    case down = 0, move = 1, up = 2, cancel = 3
}

public enum VideoCodec: UInt8 {
    case h264 = 0, av1 = 1
}

// MARK: - 帧头

public struct FrameHeader {
    public var type: UInt8 = 0
    public var flags: UInt16 = 0
    public var seq: UInt32 = 0
    public var payloadLength: UInt32 = 0

    public init(type: UInt8, flags: UInt16 = 0, seq: UInt32, payloadLength: UInt32) {
        self.type = type
        self.flags = flags
        self.seq = seq
        self.payloadLength = payloadLength
    }

    public var isKeyframe: Bool { flags & USBD.flagKeyframe != 0 }

    /// 序列化为 16 字节小端序。结构体 1 字节对齐，无隐式 padding，可安全手工编码。
    public func encode() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: USBD.headerSize)
        out[0] = USBD.magic[0]; out[1] = USBD.magic[1]
        out[2] = USBD.magic[2]; out[3] = USBD.magic[3]
        out[4] = USBD.version
        out[5] = type
        writeU16(&out, 6, flags)
        writeU32(&out, 8, seq)
        writeU32(&out, 12, payloadLength)
        return out
    }

    public static func decode(_ bytes: ArraySlice<UInt8>) -> FrameHeader? {
        guard bytes.count >= USBD.headerSize else { return nil }
        let b = Array(bytes.prefix(USBD.headerSize))
        guard b[0] == USBD.magic[0], b[1] == USBD.magic[1],
              b[2] == USBD.magic[2], b[3] == USBD.magic[3] else { return nil }
        guard b[4] == USBD.version else { return nil }
        return FrameHeader(
            type: b[5],
            flags: readU16(b, 6),
            seq: readU32(b, 8),
            payloadLength: readU32(b, 12)
        )
    }
}

// MARK: - 触摸 / 配置 / 统计

public struct TouchEvent {
    public var seq: UInt32
    public var x: UInt16          // 归一化 0..65535
    public var y: UInt16
    public var pressure: UInt16
    public var action: TouchAction
    public var pointerCount: UInt8
    public var pointerID: UInt16

    public init(seq: UInt32, x: UInt16, y: UInt16, pressure: UInt16,
                action: TouchAction, pointerCount: UInt8, pointerID: UInt16) {
        self.seq = seq; self.x = x; self.y = y; self.pressure = pressure
        self.action = action; self.pointerCount = pointerCount; self.pointerID = pointerID
    }

    public static func decode(_ payload: [UInt8]) -> TouchEvent? {
        guard payload.count >= 16 else { return nil }
        guard let action = TouchAction(rawValue: payload[10]) else { return nil }
        return TouchEvent(
            seq: readU32(payload, 0),
            x: readU16(payload, 4),
            y: readU16(payload, 6),
            pressure: readU16(payload, 8),
            action: action,
            pointerCount: payload[11],
            pointerID: readU16(payload, 12)
        )
    }

    /// 归一化坐标 → 目标显示器像素坐标，带边界钳制。
    public func point(in size: CGSize) -> CGPoint {
        let fx = min(max(CGFloat(x) / 65535.0, 0), 1)
        let fy = min(max(CGFloat(y) / 65535.0, 0), 1)
        return CGPoint(x: fx * max(0, size.width - 1), y: fy * max(0, size.height - 1))
    }
}

public struct StreamConfig {
    public var epoch: UInt32
    public var width: UInt16
    public var height: UInt16
    public var fps: UInt16
    public var codec: VideoCodec
    public var bitrateBps: UInt32

    public init(epoch: UInt32, width: UInt16, height: UInt16, fps: UInt16,
                codec: VideoCodec = .h264, bitrateBps: UInt32) {
        self.epoch = epoch; self.width = width; self.height = height
        self.fps = fps; self.codec = codec; self.bitrateBps = bitrateBps
    }

    public func encode() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        writeU32(&out, 0, epoch)
        writeU16(&out, 4, width)
        writeU16(&out, 6, height)
        writeU16(&out, 8, fps)
        out[10] = codec.rawValue
        out[11] = 0
        writeU32(&out, 12, bitrateBps)
        return out
    }
}

public struct PeerStats {
    public var rttUs: UInt32 = 0
    public var encodeUs: UInt32 = 0
    public var decodeUs: UInt32 = 0
    public var queueFrames: UInt32 = 0
    public var droppedFrames: UInt32 = 0
    public var targetBitrateBps: UInt32 = 0

    public init() {}

    public init(payload: [UInt8]) {
        var i = 0
        while i + 5 <= payload.count {
            let tag = payload[i]
            let value = readU32(payload, i + 1)
            switch tag {
            case 1: rttUs = value
            case 2: encodeUs = value
            case 3: decodeUs = value
            case 4: queueFrames = value
            case 5: droppedFrames = value
            case 6: targetBitrateBps = value
            default: break
            }
            i += 5
        }
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        append(tag: 1, value: rttUs, to: &out)
        append(tag: 2, value: encodeUs, to: &out)
        append(tag: 3, value: decodeUs, to: &out)
        append(tag: 4, value: queueFrames, to: &out)
        append(tag: 5, value: droppedFrames, to: &out)
        append(tag: 6, value: targetBitrateBps, to: &out)
        return out
    }

    private func append(tag: UInt8, value: UInt32, to out: inout [UInt8]) {
        out.append(tag)
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }
}

// MARK: - 分帧器

/// 把上层产生的 payload 拆成 帧头 + 分片，交给 USB 传输层。
/// 关键点：单个 payload 超过 USBD.maxTransfer 时切成多个连续 Bulk 写，
/// 但它们共享同一个 FrameHeader（仅第一片带头），接收端按 payload_len 累加重组。
public final class FrameFramer {
    private var seq: UInt32 = 0
    private let sink: FrameSink
    private let lock = NSRecursiveLock()

    public init(sink: FrameSink) {
        self.sink = sink
    }

    @discardableResult
    public func sendVideo(_ nalUnits: [UInt8], keyframe: Bool, timestampUs: UInt64) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let flags: UInt16 = keyframe ? USBD.flagKeyframe : 0
        let s = seq
        seq &+= 1
        let header = FrameHeader(type: USBD.typeVideo, flags: flags, seq: s,
                                 payloadLength: UInt32(nalUnits.count)).encode()
        sendFragmented(header: header, payload: nalUnits)
        return s
    }

    public func sendConfig(_ config: StreamConfig) {
        lock.lock(); defer { lock.unlock() }
        let payload = config.encode()
        let header = FrameHeader(type: USBD.typeConfig, seq: seq,
                                 payloadLength: UInt32(payload.count)).encode()
        seq &+= 1
        sendFragmented(header: header, payload: payload)
    }

    public func sendPing(timestampUs: UInt32) {
        lock.lock(); defer { lock.unlock() }
        var v = timestampUs.littleEndian
        var payload = [UInt8]()
        withUnsafeBytes(of: &v) { payload = Array($0) }
        let header = FrameHeader(type: USBD.typePing, seq: seq,
                                 payloadLength: UInt32(payload.count)).encode()
        seq &+= 1
        sink.write(header + payload)
    }

    public func sendStats(_ stats: PeerStats) {
        lock.lock(); defer { lock.unlock() }
        let payload = stats.encode()
        let header = FrameHeader(type: USBD.typeStats, seq: seq,
                                 payloadLength: UInt32(payload.count)).encode()
        seq &+= 1
        sink.write(header + payload)
    }

    private func sendFragmented(header: [UInt8], payload: [UInt8]) {
        sink.write(header + payload)
    }
    public func sendMessage(type: UInt8, payload: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let header = FrameHeader(type: type, seq: seq, payloadLength: UInt32(payload.count)).encode()
        seq &+= 1
        sink.write(header + payload)
    }
}

// MARK: - 小端读写工具

@inline(__always)
func writeU16(_ buf: inout [UInt8], _ offset: Int, _ value: UInt16) {
    buf[offset] = UInt8(value & 0xFF)
    buf[offset + 1] = UInt8((value >> 8) & 0xFF)
}

@inline(__always)
func writeU32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
    buf[offset] = UInt8(value & 0xFF)
    buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    buf[offset + 2] = UInt8((value >> 16) & 0xFF)
    buf[offset + 3] = UInt8((value >> 24) & 0xFF)
}

@inline(__always)
func readU16(_ buf: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8)
}

@inline(__always)
func readU32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(buf[offset]) | (UInt32(buf[offset + 1]) << 8)
        | (UInt32(buf[offset + 2]) << 16) | (UInt32(buf[offset + 3]) << 24)
}
