import Foundation
public final class FrameStreamParser {
    public static let maxPayload = 16 * 1024 * 1024
    private var storage: [UInt8] = []
    private var cursor = 0
    public enum ParseError: Error { case oversizedPayload }
    public init() {}
    public func append(_ bytes: [UInt8]) throws -> [ReceivedFrame] {
        storage.append(contentsOf: bytes)
        var frames: [ReceivedFrame] = []
        while storage.count - cursor >= USBD.headerSize {
            guard let h = FrameHeader.decode(storage[cursor...]) else { cursor += 1; continue }
            let size = Int(h.payloadLength)
            guard size <= Self.maxPayload else { throw ParseError.oversizedPayload }
            guard storage.count - cursor - USBD.headerSize >= size else { break }
            let start = cursor + USBD.headerSize
            frames.append(ReceivedFrame(header: h, payload: Array(storage[start..<(start+size)])))
            cursor = start+size
        }
        if cursor == storage.count { storage.removeAll(keepingCapacity: true); cursor = 0 }
        else if cursor >= 64 * 1024 { storage.removeFirst(cursor); cursor = 0 }
        return frames
    }
}
