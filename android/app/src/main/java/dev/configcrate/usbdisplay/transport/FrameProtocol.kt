package dev.configcrate.usbdisplay.transport

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * USB Display Wire Protocol v1 — Kotlin 侧定义。
 *
 * ⚠️ 必须与 `protocol/frame.h` 逐字节一致。任何字段增删都要同步改两处，
 * 并跑 `node protocol/tests/test_protocol.js` 校验。
 *
 * 全部小端序，1 字节对齐。
 */
object USBD {
    const val VERSION: Byte = 1
    const val HEADER_SIZE = 16
    const val MAX_TRANSFER = 2 * 1024 * 1024

    val MAGIC = byteArrayOf(0x55, 0x53, 0x42, 0x44) // "USBD"

    // 帧类型
    const val TYPE_VIDEO: Byte = 0x01
    const val TYPE_CONFIG: Byte = 0x02
    const val TYPE_TOUCH: Byte = 0x10
    const val TYPE_KEY: Byte = 0x11
    const val TYPE_PING: Byte = 0x20
    const val TYPE_PONG: Byte = 0x21
    const val TYPE_REQUEST_KEYFRAME: Byte = 0x30
    const val TYPE_STATS: Byte = 0x40

    // flags
    const val FLAG_KEYFRAME = 0x0001
    const val FLAG_CONFIG_EPOCH_CHANGED = 0x0002
}

enum class TouchAction(val value: Byte) {
    DOWN(0), MOVE(1), UP(2), CANCEL(3);

    companion object {
        fun from(b: Byte): TouchAction? = entries.firstOrNull { it.value == b }
    }
}

enum class VideoCodec(val value: Byte) {
    H264(0), AV1(1);

    companion object {
        fun from(b: Byte): VideoCodec = entries.firstOrNull { it.value == b } ?: H264
    }
}

/** 16 字节帧头。 */
data class FrameHeader(
    val type: Byte,
    val flags: Int,
    val seq: Long,
    val payloadLength: Int,
) {
    val isKeyframe: Boolean get() = flags and USBD.FLAG_KEYFRAME != 0
    val configEpochChanged: Boolean get() = flags and USBD.FLAG_CONFIG_EPOCH_CHANGED != 0

    fun encode(): ByteArray {
        val b = ByteBuffer.allocate(USBD.HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        b.put(USBD.MAGIC)
        b.put(USBD.VERSION)
        b.put(type)
        b.putShort(flags.toShort())
        b.putInt(seq.toInt())
        b.putInt(payloadLength)
        return b.array()
    }

    companion object {
        fun decode(buf: ByteArray, offset: Int = 0): FrameHeader? {
            if (buf.size - offset < USBD.HEADER_SIZE) return null
            for (i in USBD.MAGIC.indices) {
                if (buf[offset + i] != USBD.MAGIC[i]) return null
            }
            if (buf[offset + 4] != USBD.VERSION) return null
            val b = ByteBuffer.wrap(buf, offset, USBD.HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            b.position(offset + 6)
            val flags = b.short.toInt() and 0xFFFF
            val seq = b.int.toLong() and 0xFFFFFFFFL
            val len = b.int
            if (len < 0) return null
            return FrameHeader(buf[offset + 5], flags, seq, len)
        }
    }
}

/** 16 字节触摸事件。坐标归一化到 0..65535，与屏幕像素解耦。 */
data class TouchEvent(
    val seq: Long,
    val x: Int,
    val y: Int,
    val pressure: Int,
    val action: TouchAction,
    val pointerCount: Int,
    val pointerId: Int,
) {
    fun encode(): ByteArray {
        val b = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(seq.toInt())
        b.putShort(x.toShort())
        b.putShort(y.toShort())
        b.putShort(pressure.toShort())
        b.put(action.value)
        b.put(pointerCount.toByte())
        b.putShort(pointerId.toShort())
        b.putShort(0)
        return b.array()
    }

    companion object {
        fun decode(buf: ByteArray): TouchEvent? {
            if (buf.size < 16) return null
            val action = TouchAction.from(buf[10]) ?: return null
            val b = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
            return TouchEvent(
                seq = b.getInt(0).toLong() and 0xFFFFFFFFL,
                x = b.getShort(4).toInt() and 0xFFFF,
                y = b.getShort(6).toInt() and 0xFFFF,
                pressure = b.getShort(8).toInt() and 0xFFFF,
                action = action,
                pointerCount = buf[11].toInt() and 0xFF,
                pointerId = b.getShort(12).toInt() and 0xFFFF,
            )
        }
    }
}

/** 16 字节流配置，Mac 侧分辨率/帧率变更时下发。 */
data class StreamConfig(
    val epoch: Long,
    val width: Int,
    val height: Int,
    val fps: Int,
    val codec: VideoCodec,
    val bitrateBps: Long,
) {
    companion object {
        fun decode(buf: ByteArray): StreamConfig? {
            if (buf.size < 16) return null
            val b = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
            return StreamConfig(
                epoch = b.getInt(0).toLong() and 0xFFFFFFFFL,
                width = b.getShort(4).toInt() and 0xFFFF,
                height = b.getShort(6).toInt() and 0xFFFF,
                fps = b.getShort(8).toInt() and 0xFFFF,
                codec = VideoCodec.from(buf[10]),
                bitrateBps = b.getInt(12).toLong() and 0xFFFFFFFFL,
            )
        }
    }
}

/** 对端统计，用于自适应码率闭环。 */
data class PeerStats(
    var rttUs: Long = 0,
    var encodeUs: Long = 0,
    var decodeUs: Long = 0,
    var queueFrames: Long = 0,
    var droppedFrames: Long = 0,
    var targetBitrateBps: Long = 0,
) {
    fun encode(): ByteArray {
        val entries = listOf(
            1 to rttUs, 2 to encodeUs, 3 to decodeUs,
            4 to queueFrames, 5 to droppedFrames, 6 to targetBitrateBps,
        )
        val b = ByteBuffer.allocate(entries.size * 5).order(ByteOrder.LITTLE_ENDIAN)
        entries.forEach { (tag, value) ->
            b.put(tag.toByte())
            b.putInt(value.toInt())
        }
        return b.array()
    }

    companion object {
        fun decode(buf: ByteArray): PeerStats {
            val stats = PeerStats()
            var i = 0
            while (i + 5 <= buf.size) {
                val tag = buf[i].toInt() and 0xFF
                val value = ByteBuffer.wrap(buf, i + 1, 4)
                    .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
                when (tag) {
                    1 -> stats.rttUs = value
                    2 -> stats.encodeUs = value
                    3 -> stats.decodeUs = value
                    4 -> stats.queueFrames = value
                    5 -> stats.droppedFrames = value
                    6 -> stats.targetBitrateBps = value
                }
                i += 5
            }
            return stats
        }
    }
}
