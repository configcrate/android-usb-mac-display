package dev.configcrate.usbdisplay.transport

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * AOA Accessory 侧传输。
 *
 * Android 作为 accessory 时，系统会给出一个 [UsbAccessory] 和一个
 * [ParcelFileDescriptor]，后者就是与主机通信的双向流：
 *   - FileInputStream  = Bulk IN （接收 Mac 发来的视频）
 *   - FileOutputStream = Bulk OUT（回传触摸/按键/请求关键帧）
 *
 * 线程模型：
 *   - reader 线程：高优先级，持续读并流式重组帧，回调 [onFrame]
 *   - writer 线程：高优先级，从有界队列取数据批量写，队列满则丢弃最老的（背压）
 *
 * ⚠️ 绝不在 UI 线程读写 USB：一次 bulk 写可能阻塞数毫秒，会直接导致掉帧。
 */
class UsbAccessoryTransport(
    private val usbManager: UsbManager,
    private val accessory: UsbAccessory,
) {
    companion object {
        private const val TAG = "UsbTransport"
        private const val READ_CHUNK = 64 * 1024
        /** 写队列上限：超了说明 USB 拥塞，宁可丢帧也不能让延迟无限增长 */
        private const val WRITE_QUEUE_CAPACITY = 64
        /** 防御性上界，防止错位后 payloadLength 变成天文数字导致 OOM */
        private const val MAX_PAYLOAD = 64 * 1024 * 1024
    }

    private var fd: ParcelFileDescriptor? = null
    private var input: FileInputStream? = null
    private var output: FileOutputStream? = null

    private val running = AtomicBoolean(false)
    private var readerThread: Thread? = null
    private var writerThread: Thread? = null

    private val writeQueue = ArrayBlockingQueue<ByteArray>(WRITE_QUEUE_CAPACITY)

    /** 收到的逻辑帧。payload 为独立拷贝，可安全跨线程传递。 */
    var onFrame: ((FrameHeader, ByteArray) -> Unit)? = null
    var onError: ((Throwable) -> Unit)? = null

    /** 置 true 时统计丢帧，供 UI 展示 */
    @Volatile var droppedBuffers: Long = 0
        private set

    // ---- 生命周期 ----

    fun open(): Boolean {
        val descriptor = usbManager.openAccessory(accessory) ?: run {
            Log.e(TAG, "openAccessory 返回 null，设备可能已被其他 App 占用")
            return false
        }
        fd = descriptor
        input = FileInputStream(descriptor.fileDescriptor)
        output = FileOutputStream(descriptor.fileDescriptor)
        running.set(true)
        startReader()
        startWriter()
        Log.i(TAG, "已连接 accessory: ${accessory.model} / ${accessory.manufacturer}")
        return true
    }

    fun close() {
        running.set(false)
        readerThread?.interrupt()
        writerThread?.interrupt()
        readerThread = null
        writerThread = null
        writeQueue.clear()
        runCatching { input?.close() }
        runCatching { output?.close() }
        runCatching { fd?.close() }
        input = null
        output = null
        fd = null
    }

    // ---- 读：流式重组 ----

    private fun startReader() {
        readerThread = Thread({ readLoop() }, "usbd-reader").apply {
            // 音频级优先级：USB 读延迟直接体现在玻璃到玻璃延迟上
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    /**
     * 读循环。
     *
     * 重组要点：一次 read 返回的字节数任意，一个逻辑帧可能跨多次 read。
     * 必须按 payloadLength 累加，绝不能假设「一次读 = 一帧」。
     */
    private fun readLoop() {
        val chunk = ByteArray(READ_CHUNK)
        var acc = ByteArray(0)
        var header: FrameHeader? = null
        var need = 0

        try {
            while (running.get()) {
                val n = input?.read(chunk) ?: break
                if (n < 0) {
                    Log.w(TAG, "读到流末尾，主机可能已断开")
                    break
                }
                if (n == 0) continue

                acc = if (acc.isEmpty()) {
                    chunk.copyOf(n)
                } else {
                    val merged = ByteArray(acc.size + n)
                    System.arraycopy(acc, 0, merged, 0, acc.size)
                    System.arraycopy(chunk, 0, merged, acc.size, n)
                    merged
                }

                var consumed = 0
                while (true) {
                    if (header == null) {
                        if (acc.size - consumed < USBD.HEADER_SIZE) break
                        val h = FrameHeader.decode(acc, consumed)
                        if (h == null) {
                            // 头无效：跳一个字节重新同步，避免错位后永久卡死
                            consumed += 1
                            continue
                        }
                        if (h.payloadLength > MAX_PAYLOAD) {
                            Log.w(TAG, "payloadLength 异常 ${h.payloadLength}，重置流")
                            consumed = acc.size
                            break
                        }
                        header = h
                        need = h.payloadLength
                        consumed += USBD.HEADER_SIZE
                    }

                    val h = header ?: break
                    if (acc.size - consumed < need) break

                    val payload = acc.copyOfRange(consumed, consumed + need)
                    consumed += need
                    header = null
                    need = 0

                    onFrame?.invoke(h, payload)
                }

                // 压缩已消费部分，避免 acc 无限增长
                if (consumed > 0) {
                    acc = if (consumed >= acc.size) ByteArray(0)
                    else acc.copyOfRange(consumed, acc.size)
                }
            }
        } catch (t: Throwable) {
            if (running.get()) {
                Log.e(TAG, "读循环异常", t)
                onError?.invoke(t)
            }
        }
    }

    // ---- 写：带背压的批量写 ----

    private fun startWriter() {
        writerThread = Thread({ writeLoop() }, "usbd-writer").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun writeLoop() {
        try {
            while (running.get()) {
                val first = writeQueue.take()
                // 批量合并，减少 syscall 与 USB 事务次数
                val batch = ArrayList<ByteArray>(8)
                batch.add(first)
                writeQueue.drainTo(batch, 7)

                val out = output ?: break
                for (buf in batch) {
                    out.write(buf)
                }
                out.flush()
            }
        } catch (t: InterruptedException) {
            // 正常退出路径
        } catch (t: Throwable) {
            if (running.get()) {
                Log.e(TAG, "写循环异常", t)
                onError?.invoke(t)
            }
        }
    }

    /**
     * 发送一帧（自动加帧头）。
     *
     * 背压策略：队列满时丢弃**最老**的一条。实时投屏场景下，
     * 迟到的触摸事件比丢失的触摸事件更糟 —— 它会让光标"追赶"而不是"跟手"。
     */
    fun send(type: Byte, payload: ByteArray, flags: Int = 0): Boolean {
        val header = FrameHeader(type = type, flags = flags, seq = nextSeq(), payloadLength = payload.size)
        val frame = header.encode() + payload
        return if (writeQueue.offer(frame)) {
            true
        } else {
            // 队列满：丢掉最老的，再塞入新的
            writeQueue.poll()
            droppedBuffers++
            writeQueue.offer(frame)
            false
        }
    }

    fun sendTouch(event: TouchEvent) {
        send(USBD.TYPE_TOUCH, event.encode())
    }

    fun sendRequestKeyframe() {
        send(USBD.TYPE_REQUEST_KEYFRAME, ByteArray(0))
    }

    fun sendPing(timestampUs: Long) {
        val b = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(timestampUs.toInt())
        send(USBD.TYPE_PING, b.array())
    }

    fun sendPong(echoedTimestampUs: Long, localTimestampUs: Long) {
        val b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(echoedTimestampUs.toInt())
        b.putInt(localTimestampUs.toInt())
        send(USBD.TYPE_PONG, b.array())
    }

    fun sendStats(stats: PeerStats) {
        send(USBD.TYPE_STATS, stats.encode())
    }

    private val seqCounter = java.util.concurrent.atomic.AtomicLong(0)
    private fun nextSeq(): Long = seqCounter.incrementAndGet() and 0xFFFFFFFFL
}
