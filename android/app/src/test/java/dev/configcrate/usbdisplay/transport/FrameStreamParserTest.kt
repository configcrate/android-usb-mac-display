package dev.configcrate.usbdisplay.transport
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
class FrameStreamParserTest {
    @Test fun tinyReadsGarbageAndLargePayload() {
        val parser=FrameStreamParser()
        val payload=ByteArray(3*1024*1024+777) { 0x4c }
        val wire=byteArrayOf(5,6,7)+FrameHeader(USBD.TYPE_VIDEO,0,1,payload.size).encode()+payload
        val result=ArrayList<ByteArray>()
        var i=0
        while (i<wire.size) {
            parser.append(wire.copyOfRange(i,minOf(i+7,wire.size))) { _, p -> result.add(p) }
            i+=7
        }
        assertEquals(1,result.size); assertArrayEquals(payload,result[0])
    }
    @Test fun zeroLengthAndConsecutiveFrames() {
        val parser=FrameStreamParser()
        val frame=FrameHeader(USBD.TYPE_REQUEST_KEYFRAME,0,1,0).encode()
        var count=0
        parser.append(frame+frame) { _, _ -> count++ }
        assertEquals(2,count)
    }
    @Test(expected=IOException::class) fun oversizedPayloadRejectedBeforeAllocation() {
        FrameStreamParser(100).append(FrameHeader(USBD.TYPE_VIDEO,0,1,101).encode()) { _, _ -> fail() }
    }
    @Test fun unsignedPingTokenWrap() {
        assertEquals(1L,(0xffffffffL+2) and 0xffffffffL)
    }
}
