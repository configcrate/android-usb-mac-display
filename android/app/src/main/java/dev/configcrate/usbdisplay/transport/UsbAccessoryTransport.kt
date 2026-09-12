package dev.configcrate.usbdisplay.transport

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class UsbAccessoryTransport(private val manager: UsbManager, private val accessory: UsbAccessory) {
    private var fd: ParcelFileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null
    private val running = AtomicBoolean(false)
    val isOpen: Boolean get() = running.get()
    private var reader: Thread? = null
    private var writer: Thread? = null
    private val writes = ArrayBlockingQueue<ByteArray>(64)
    private var seq = 0L
    var onFrame: ((FrameHeader, ByteArray) -> Unit)? = null
    var onError: ((Throwable) -> Unit)? = null
    @Volatile var droppedBuffers = 0L
        private set
    fun open(): Boolean {
        if (isOpen) return true
        val descriptor = manager.openAccessory(accessory) ?: return false
        fd = descriptor
        input = FileInputStream(descriptor.fileDescriptor)
        output = FileOutputStream(descriptor.fileDescriptor)
        running.set(true)
        reader = Thread({ readLoop() }, "usbd-reader").apply { start() }
        writer = Thread({ writeLoop() }, "usbd-writer").apply { start() }
        return true
    }
    private fun releaseStreams() {
        reader?.interrupt(); writer?.interrupt()
        runCatching { fd?.close() }
        runCatching { input?.close() }; runCatching { output?.close() }
        writes.clear()
    }
    fun close() { running.set(false); releaseStreams() }
    private fun fail(error: Throwable) {
        if (running.getAndSet(false)) { releaseStreams(); onError?.invoke(error) }
    }
    private fun readLoop() {
        val bytes = ByteArray(64 * 1024)
        val parser = FrameStreamParser()
        try {
            while (isOpen) {
                val n = input?.read(bytes) ?: throw IOException("USB input closed")
                if (n < 0) throw IOException("Mac disconnected")
                if (n > 0) parser.append(bytes, n) { h, p -> onFrame?.invoke(h, p) }
            }
        } catch (error: Throwable) { fail(error) }
    }
    private fun writeLoop() {
        try {
            while (isOpen) {
                val bytes = writes.take()
                val stream = output ?: throw IOException("USB output closed")
                stream.write(bytes)
            }
        } catch (_: InterruptedException) {
        } catch (error: Throwable) { fail(error) }
    }
    @Synchronized
    fun send(type: Byte, payload: ByteArray, flags: Int = 0): Boolean {
        if (!isOpen) return false
        seq = (seq + 1) and 0xffffffffL
        val bytes = FrameHeader(type, flags, seq, payload.size).encode() + payload
        if (writes.offer(bytes)) return true
        // Only expendable telemetry / pointer moves may be dropped.
        // Losing UP/CANCEL can leave the Mac mouse pressed indefinitely.
        val move = type == USBD.TYPE_TOUCH && payload.size == 16 && payload[10] == TouchAction.MOVE.value
        if (move || type == USBD.TYPE_PING || type == USBD.TYPE_STATS) {
            droppedBuffers++; return false
        }
        fail(IOException("USB control queue full; reconnect to recover safely"))
        return false
    }
    fun sendTouch(event: TouchEvent) { send(USBD.TYPE_TOUCH, event.encode()) }
    fun sendRequestKeyframe() { send(USBD.TYPE_REQUEST_KEYFRAME, ByteArray(0)) }
    fun sendPing(token: Long) {
        send(USBD.TYPE_PING, ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(token.toInt()).array())
    }
    fun sendPong(token: Long, localUs: Long) {
        send(USBD.TYPE_PONG, ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(token.toInt()).putInt(localUs.toInt()).array())
    }
    fun sendStats(stats: PeerStats) { send(USBD.TYPE_STATS, stats.encode()) }
}
