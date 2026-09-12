package dev.configcrate.usbdisplay.transport

import java.io.IOException

/** Incremental parser; no repeated copying of the entire unfinished payload. */
class FrameStreamParser(private val maxPayload: Int = 16 * 1024 * 1024) {
    private val headerBytes = ByteArray(USBD.HEADER_SIZE)
    private var headerCount = 0
    private var header: FrameHeader? = null
    private var payload = ByteArray(0)
    private var payloadCount = 0
    fun append(bytes: ByteArray, size: Int = bytes.size, receive: (FrameHeader, ByteArray) -> Unit) {
        require(size in 0..bytes.size)
        var offset = 0
        while (offset < size) {
            if (header == null) {
                val n = minOf(USBD.HEADER_SIZE - headerCount, size - offset)
                System.arraycopy(bytes, offset, headerBytes, headerCount, n)
                offset += n; headerCount += n
                if (headerCount < USBD.HEADER_SIZE) continue
                val decoded = FrameHeader.decode(headerBytes)
                if (decoded == null) {
                    System.arraycopy(headerBytes, 1, headerBytes, 0, USBD.HEADER_SIZE - 1)
                    headerCount = USBD.HEADER_SIZE - 1
                    continue
                }
                if (decoded.payloadLength > maxPayload) throw IOException("Oversized USB payload")
                header = decoded; payload = ByteArray(decoded.payloadLength); payloadCount = 0
                if (payload.isEmpty()) {
                    header = null; headerCount = 0
                    receive(decoded, payload)
                    continue
                }
            }
            val current = header ?: continue
            val n = minOf(payload.size - payloadCount, size - offset)
            System.arraycopy(bytes, offset, payload, payloadCount, n)
            offset += n; payloadCount += n
            if (payloadCount == payload.size) {
                val complete = payload
                header = null; headerCount = 0; payload = ByteArray(0); payloadCount = 0
                receive(current, complete)
            }
        }
    }
}
