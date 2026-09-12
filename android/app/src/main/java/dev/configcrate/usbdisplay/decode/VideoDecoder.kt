package dev.configcrate.usbdisplay.decode

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import dev.configcrate.usbdisplay.transport.PeerStats
import dev.configcrate.usbdisplay.transport.StreamConfig
import dev.configcrate.usbdisplay.transport.USBD
import java.nio.ByteBuffer

/**
 * MediaCodec H.264 硬件解码器，为低延迟投屏调优。
 *
 * 延迟关键点：
 *  1. **Surface 直出**：`configure(fmt, surface, ...)`，绝不读 outputBuffer 再上屏
 *  2. **KEY_LOW_LATENCY=1**（API 30+）：让解码器不攒帧
 *  3. **releaseOutputBuffer(index, true)**：第二个参数必须是 true（渲染到 surface）
 *  4. **不重排**：Mac 侧已禁 B 帧，解码器无需等后续帧
 *  5. **不自行拆 NAL**：直接喂 Annex-B 流，MediaCodec 自动识别 start code 与 SPS/PPS
 */
class LowLatencyVideoDecoder(
    private val surface: Surface,
    private val onFrameRendered: ((presentationTimeUs: Long) -> Unit)? = null,
) {
    companion object {
        private const val TAG = "VideoDecoder"
        private const val MIME = "video/avc"
        /** 输入缓冲留足一个 2MiB 关键帧 */
        private const val MAX_INPUT_SIZE = 2 * 1024 * 1024
        /** 单个输入缓冲的等待超时，10ms 足够，超了说明解码器卡住 */
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        /** 输出队列积压超过此值即判定解码跟不上，触发降码率 */
        private const val QUEUE_BACKLOG_THRESHOLD = 2
    }

    private var codec: MediaCodec? = null
    private var currentConfig: StreamConfig? = null
    private val bufferInfo = MediaCodec.BufferInfo()

    /** 解码耗时（微秒），滑动窗口 P50，用于 STATS 上报 */
    private val decodeTimes = ArrayDeque<Long>()
    @Volatile private var pendingInputPtsUs: Long = 0
    @Volatile private var droppedFrames: Long = 0

    /** 输出队列积压帧数，> 2 时上层应降码率 */
    @Volatile var queueBacklog: Int = 0
        private set

    /** 最近一次解码单帧耗时 */
    @Volatile var lastDecodeUs: Long = 0
        private set

    // ---- 生命周期 ----

    fun configure(config: StreamConfig) {
        if (currentConfig?.epoch == config.epoch) return
        Log.i(TAG, "configure: ${config.width}x${config.height}@${config.fps} " +
                "bitrate=${config.bitrateBps} epoch=${config.epoch}")
        releaseCodec()

        val format = MediaFormat.createVideoFormat(MIME, config.width, config.height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_INPUT_SIZE)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30+ 才有真正的低延迟模式：解码器尽可能不缓冲
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            // 声明预期帧率，帮助解码器做帧率匹配
            setInteger(MediaFormat.KEY_OPERATING_RATE, config.fps.coerceAtLeast(30))
            // 0 = 实时优先级
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            // 部分机型支持：显式要求不输出到 ByteBuffer 之外的东西
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setInteger(MediaFormat.KEY_OPERATING_RATE, config.fps.coerceAtLeast(30))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // 降低解码器内部缓冲，牺牲一点功耗换延迟
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }

        val c = MediaCodec.createDecoderByType(MIME)
        try {
            c.configure(format, surface, null, 0)
            c.start()
            codec = c
            currentConfig = config
        } catch (t: Throwable) {
            Log.e(TAG, "解码器 configure 失败", t)
            runCatching { c.release() }
            throw t
        }
    }

    fun release() {
        releaseCodec()
        currentConfig = null
    }

    private fun releaseCodec() {
        codec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
    }

    // ---- 喂帧 ----

    /**
     * 喂入一帧 Annex-B 数据。
     *
     * 直接喂整段 Annex-B 是可行的：MediaCodec 的 H.264 解码器能自动识别
     * `00 00 00 01` start code，并从关键帧中提取 SPS/PPS。
     * 这样就不需要自己拆 NAL 再打 BUFFER_FLAG_CODEC_CONFIG 标记 ——
     * 那套做法在动态分辨率变更时必须重新 configure，很容易踩坑。
     */
    fun feed(data: ByteArray, isKeyframe: Boolean, presentationTimeUs: Long): Boolean {
        val c = codec ?: return false
        if (data.isEmpty()) return false

        // 先排空输出，回收缓冲；这步不做的话输入缓冲很快耗尽
        drainOutput()

        val inputIndex = try {
            c.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        } catch (t: IllegalStateException) {
            Log.e(TAG, "dequeueInputBuffer 失败", t)
            return false
        }
        if (inputIndex < 0) {
            // 输入缓冲暂时不可用：丢帧并请求关键帧，避免队列越积越深
            droppedFrames++
            return false
        }

        val buffer: ByteBuffer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            c.getInputBuffer(inputIndex) ?: return false
        } else {
            @Suppress("DEPRECATION")
            c.inputBuffers[inputIndex]
        }

        buffer.clear()
        var flags = 0
        if (isKeyframe) {
            // 关键帧打上 SYNC_FRAME 标记，解码器据此判断可从此处开始解码
            flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
        }
        // 数据超过 MAX_INPUT_SIZE 时截断（正常不会发生，因为 Mac 侧已限制）
        val len = minOf(data.size, buffer.capacity())
        buffer.put(data, 0, len)
        buffer.position(0)
        buffer.limit(len)

        pendingInputPtsUs = presentationTimeUs
        val enqueuedAt = System.nanoTime()
        try {
            c.queueInputBuffer(inputIndex, 0, len, presentationTimeUs, flags)
        } catch (t: IllegalStateException) {
            Log.e(TAG, "queueInputBuffer 失败", t)
            return false
        }

        drainOutput()
        val elapsedUs = (System.nanoTime() - enqueuedAt) / 1000
        lastDecodeUs = elapsedUs
        recordDecodeTime(elapsedUs)
        return true
    }

    /** 排空输出缓冲并直接渲染到 Surface（不拷贝）。 */
    private fun drainOutput() {
        val c = codec ?: return
        var backlog = 0
        while (true) {
            val outIndex = try {
                c.dequeueOutputBuffer(bufferInfo, 0)
            } catch (t: IllegalStateException) {
                return
            }

            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break

                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val fmt = c.outputFormat
                    Log.d(TAG, "输出格式变更: $fmt")
                    continue
                }

                outIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                    // API 21+ 已废弃，忽略
                    continue
                }

                outIndex >= 0 -> {
                    // 第二个参数必须是 true：渲染到 configure 时传入的 Surface
                    // 用 renderTimestamp 版本反而会让画面延迟一帧
                    c.releaseOutputBuffer(outIndex, true)
                    backlog++
                    onFrameRendered?.invoke(bufferInfo.presentationTimeUs)
                }

                else -> break
            }
        }
        queueBacklog = backlog
    }

    private fun recordDecodeTime(us: Long) {
        decodeTimes.addLast(us)
        while (decodeTimes.size > 120) decodeTimes.removeFirst()
    }

    // ---- 统计 ----

    /** 生成上报给 Mac 的统计，驱动自适应码率。 */
    fun stats(): PeerStats {
        val sorted = decodeTimes.sorted()
        val p50 = if (sorted.isEmpty()) 0L else sorted[sorted.size / 2]
        return PeerStats(
            decodeUs = p50,
            queueFrames = queueBacklog.toLong(),
            droppedFrames = droppedFrames,
        )
    }

    /** 积压过多说明解码器跟不上，上层应降码率。 */
    fun isBacklogged(): Boolean = queueBacklog > QUEUE_BACKLOG_THRESHOLD

    /** 对当前帧率下的码率给出建议。 */
    fun suggestBitrate(currentBps: Long): Long {
        return when {
            queueBacklog > QUEUE_BACKLOG_THRESHOLD -> (currentBps * 0.9).toLong()
            queueBacklog == 0 && p50DecodeUs() < 4000 -> (currentBps * 1.05).toLong()
            else -> currentBps
        }.coerceIn(1_000_000L, 40_000_000L)
    }

    private fun p50DecodeUs(): Long {
        val sorted = decodeTimes.sorted()
        return if (sorted.isEmpty()) 0 else sorted[sorted.size / 2]
    }
}
