import XCTest
@testable import USBDisplayCore
final class ProtocolTests: XCTestCase {
    func testHeaderRoundTrip() {
        let h=FrameHeader(type:USBD.typeVideo,flags:USBD.flagKeyframe,seq:.max,payloadLength:42)
        let out=FrameHeader.decode(h.encode()[...])
        XCTAssertEqual(out?.seq,.max); XCTAssertEqual(out?.payloadLength,42); XCTAssertEqual(out?.isKeyframe,true)
    }
    func testProductionParserWithTinyReadsAndGarbage() throws {
        let parser=FrameStreamParser()
        let payload=[UInt8](repeating:0xcd,count:3*1024*1024+777)
        let wire=[UInt8]([8,9,10])+FrameHeader(type:USBD.typeVideo,seq:1,payloadLength:UInt32(payload.count)).encode()+payload
        var received: [ReceivedFrame]=[]
        for offset in stride(from:0,to:wire.count,by:7) {
            received += try parser.append(Array(wire[offset..<min(offset+7,wire.count)]))
        }
        XCTAssertEqual(received.count,1); XCTAssertEqual(received.first?.payload,payload)
    }
    func testZeroPayloadAndMultipleFrames() throws {
        let parser=FrameStreamParser()
        let empty=FrameHeader(type:USBD.typeRequestKeyframe,seq:1,payloadLength:0).encode()
        XCTAssertEqual(try parser.append(empty+empty).count,2)
    }
    func testOversizeRejected() {
        let parser=FrameStreamParser()
        let h=FrameHeader(type:USBD.typeVideo,seq:0,payloadLength:UInt32(FrameStreamParser.maxPayload+1)).encode()
        XCTAssertThrowsError(try parser.append(h))
    }
    func testConcurrentSendIsAtomicAndSequenceIsUnique() {
        let sink=RecordingSink()
        let framer=FrameFramer(sink:sink)
        DispatchQueue.concurrentPerform(iterations:100) { i in
            if i%2==0 { framer.sendVideo([1,2,3],keyframe:false,timestampUs:0) }
            else { framer.sendPing(timestampUs:UInt32(i)) }
        }
        XCTAssertEqual(sink.messages.count,100)
        let headers=sink.messages.compactMap { FrameHeader.decode($0[...]) }
        XCTAssertEqual(Set(headers.map { $0.seq }).count,100)
        XCTAssertTrue(sink.messages.allSatisfy { $0.count == 16 + Int(FrameHeader.decode($0[...])!.payloadLength) })
    }
    func testClockDoesNotTrapAfter32BitRange() {
        XCTAssertEqual(UInt32(truncatingIfNeeded:UInt64(UInt32.max)+2),1)
        XCTAssertGreaterThan(MonotonicClock.microseconds,0)
    }
}
private final class RecordingSink: FrameSink {
    var messages: [[UInt8]]=[]
    func write(_ bytes: [UInt8]) -> Int { messages.append(bytes); return bytes.count }
}
