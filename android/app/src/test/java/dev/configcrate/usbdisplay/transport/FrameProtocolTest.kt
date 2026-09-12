package dev.configcrate.usbdisplay.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 协议编解码测试。
 *
 * 这些用例与 `protocol/tests/test_protocol.js` 是**同一套语义**的两份实现，
 * 两边都必须通过，才能保证 Mac(Swift) 与 Android(Kotlin) 真正互通。
 * 任何协议字段变更都要同时更新三处：frame.h / FrameProtocol.swift / FrameProtocol.kt。
 */
class FrameProtocolTest {

    @Test
    fun `帧头固定 16 字节`() {
        val header = FrameHeader(USBD.TYPE_VIDEO, 0, 0, 0)
        assertEquals(16, header.encode().size)
    }

    @Test
    fun `帧头往返编解码`() {
        val src = FrameHeader(
            type = USBD.TYPE_VIDEO,
            flags = USBD.FLAG_KEYFRAME,
            seq = 0xDEADBEEFL,
            payloadLength = 123456,
        )
        val decoded = FrameHeader.decode(src.encode())
        assertNotNull(decoded)
        assertEquals(src.type, decoded!!.type)
        assertEquals(src.flags, decoded.flags)
        assertEquals(src.seq, decoded.seq)
        assertEquals(src.payloadLength, decoded.payloadLength)
    }

    @Test
    fun `magic 不匹配时返回 null`() {
        val bytes = FrameHeader(USBD.TYPE_VIDEO, 0, 0, 0).encode()
        bytes[0] = 0x00
        assertNull(FrameHeader.decode(bytes))
    }

    @Test
    fun `seq 为最大值时不丢精度`() {
        val src = FrameHeader(USBD.TYPE_VIDEO, 0, 0xFFFFFFFFL, 0)
        assertEquals(0xFFFFFFFFL, FrameHeader.decode(src.encode())!!.seq)
    }

    @Test
    fun `触摸事件固定 16 字节`() {
        val event = TouchEvent(1, 100, 200, 300, TouchAction.DOWN, 1, 0)
        assertEquals(16, event.encode().size)
    }

    @Test
    fun `触摸事件往返编解码`() {
        val src = TouchEvent(
            seq = 42,
            x = 32768,
            y = 65535,
            pressure = 1000,
            action = TouchAction.MOVE,
            pointerCount = 2,
            pointerId = 7,
        )
        val decoded = TouchEvent.decode(src.encode())
        assertEquals(src, decoded)
    }

    @Test
    fun `触摸坐标边界值正确`() {
        val decoded = TouchEvent.decode(
            TouchEvent(0, 65535, 0, 0, TouchAction.DOWN, 1, 0).encode()
        )!!
        assertEquals(65535, decoded.x)
        assertEquals(0, decoded.y)
    }

    @Test
    fun `未知 action 返回 null`() {
        val bytes = TouchEvent(0, 0, 0, 0, TouchAction.DOWN, 1, 0).encode()
        bytes[10] = 99
        assertNull(TouchEvent.decode(bytes))
    }

    @Test
    fun `STATS TLV 往返编解码`() {
        val src = PeerStats(
            rttUs = 2500,
            encodeUs = 3000,
            decodeUs = 4000,
            queueFrames = 0,
            droppedFrames = 12,
            targetBitrateBps = 8_000_000,
        )
        val decoded = PeerStats.decode(src.encode())
        assertEquals(src.rttUs, decoded.rttUs)
        assertEquals(src.encodeUs, decoded.encodeUs)
        assertEquals(src.decodeUs, decoded.decodeUs)
        assertEquals(0L, decoded.queueFrames)
        assertEquals(src.droppedFrames, decoded.droppedFrames)
        assertEquals(src.targetBitrateBps, decoded.targetBitrateBps)
    }

    @Test
    fun `STATS 每条 TLV 恰好 5 字节`() {
        assertEquals(30, PeerStats().encode().size)
    }

    @Test
    fun `StreamConfig 往返编解码`() {
        val bytes = java.nio.ByteBuffer.allocate(16)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .apply {
                putInt(7)             // epoch
                putShort(2560)        // width
                putShort(1440)        // height
                putShort(60)          // fps
                put(VideoCodec.H264.value)
                put(0)
                putInt(20_000_000)    // bitrate
            }.array()

        val cfg = StreamConfig.decode(bytes)!!
        assertEquals(7L, cfg.epoch)
        assertEquals(2560, cfg.width)
        assertEquals(1440, cfg.height)
        assertEquals(60, cfg.fps)
        assertEquals(VideoCodec.H264, cfg.codec)
        assertEquals(20_000_000L, cfg.bitrateBps)
    }

    @Test
    fun `关键帧 flag 位判断正确`() {
        val h = FrameHeader(
            USBD.TYPE_VIDEO,
            USBD.FLAG_KEYFRAME or USBD.FLAG_CONFIG_EPOCH_CHANGED,
            0, 0,
        )
        assertTrue(h.isKeyframe)
        assertTrue(h.configEpochChanged)
    }

    @Test
    fun `流式重组能还原被切分的帧`() {
        // 模拟 Mac 侧把 3MiB 载荷切成多个 <= 2MiB 的片
        val payload = ByteArray(3 * 1024 * 1024 + 777) { 0xCD.toByte() }
        val header = FrameHeader(USBD.TYPE_VIDEO, 0, 1, payload.size)
        val max = USBD.MAX_TRANSFER
        val wire = mutableListOf<ByteArray>()

        if (payload.size + USBD.HEADER_SIZE <= max) {
            wire.add(header.encode() + payload)
        } else {
            var offset = 0
            var first = true
            val chunkSize = max - USBD.HEADER_SIZE
            while (offset < payload.size) {
                val end = minOf(offset + chunkSize, payload.size)
                val slice = payload.copyOfRange(offset, end)
                wire.add(if (first) header.encode() + slice else slice)
                first = false
                offset = end
            }
        }
        assertTrue(wire.all { it.size <= max })

        // 接收端：模拟部分读（每 7 字节一次）
        var acc = ByteArray(0)
        var pending: FrameHeader? = null
        var need = 0
        val frames = mutableListOf<Pair<FrameHeader, ByteArray>>()

        for (w in wire) {
            var i = 0
            while (i < w.size) {
                val n = minOf(7, w.size - i)
                acc += w.copyOfRange(i, i + n)
                i += n
            }
            var consumed = 0
            var frameDone = false
            // 注意：不要在 inline lambda（这里的 run {}）里用 break/continue，
            // 那是实验特性，Kotlin 1.9 需要额外开编译器 flag。这里用布尔哨兵表达。
            while (!frameDone) {
                if (pending == null) {
                    if (acc.size - consumed < USBD.HEADER_SIZE) break
                    val h = FrameHeader.decode(acc, consumed)
                    if (h == null) {
                        // 头无效：跳一个字节重新同步
                        consumed += 1
                        continue
                    }
                    pending = h
                    need = h.payloadLength
                    consumed += USBD.HEADER_SIZE
                }
                if (acc.size - consumed < need) break
                frames.add(pending to acc.copyOfRange(consumed, consumed + need))
                consumed += need
                pending = null
                need = 0
            }
            acc = if (consumed >= acc.size) ByteArray(0) else acc.copyOfRange(consumed, acc.size)
        }

        assertEquals(1, frames.size)
        assertEquals(payload.size, frames[0].second.size)
        assertArrayEquals(payload, frames[0].second)
    }
}
