package dev.configcrate.usbdisplay.decode

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import dev.configcrate.usbdisplay.transport.PeerStats
import dev.configcrate.usbdisplay.transport.StreamConfig

/** Serialises codec lifecycle/feed/drain via one monitor. Output polling also
 * runs during static scenes, so the last frame does not wait for new input. */
class LowLatencyVideoDecoder(private val surface: Surface) {
    private var codec: MediaCodec? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private val info = MediaCodec.BufferInfo()
    private val submitted = LinkedHashMap<Long, Long>()
    private val durations = ArrayDeque<Long>()
    private var dropped = 0L
    private var failed = false
    @Volatile var queueBacklog = 0
        private set
    @Volatile var lastDecodeUs = 0L
        private set
    @Synchronized fun configure(config: StreamConfig) {
        release()
        val format = MediaFormat.createVideoFormat("video/avc", config.width, config.height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8 * 1024 * 1024)
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_OPERATING_RATE, config.fps)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        val c = MediaCodec.createDecoderByType("video/avc")
        try {
            c.configure(format, surface, null, 0); c.start()
            c.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            codec = c; failed = false
        } catch (error: Exception) { runCatching { c.release() }; throw error }
        val worker = HandlerThread("usbd-output").apply { start() }
        thread = worker
        val outputHandler = Handler(worker.looper)
        handler = outputHandler
        outputHandler.post(object : Runnable {
            override fun run() {
                synchronized(this@LowLatencyVideoDecoder) {
                    if (codec == null || handler !== outputHandler) return
                    drainOutput()
                }
                outputHandler.postDelayed(this, 8)
            }
        })
    }
    @Synchronized fun release() {
        handler?.removeCallbacksAndMessages(null); handler = null
        thread?.quitSafely(); thread = null
        val old = codec; codec = null
        old?.let { runCatching { it.stop() }; runCatching { it.release() } }
        submitted.clear(); queueBacklog = 0
    }
    @Synchronized fun feed(data: ByteArray, isKeyframe: Boolean, presentationTimeUs: Long): Boolean {
        val c = codec ?: return false
        if (failed || data.isEmpty() || data.size > 8 * 1024 * 1024) { dropped++; return false }
        try {
            drainOutput()
            val index = c.dequeueInputBuffer(10_000)
            if (index < 0) { dropped++; return false }
            val buffer = c.getInputBuffer(index) ?: run { failed = true; return false }
            buffer.clear()
            if (data.size > buffer.capacity()) {
                // Return the dequeued buffer without sending truncated H.264.
                c.queueInputBuffer(index, 0, 0, presentationTimeUs, 0)
                dropped++; return false
            }
            buffer.put(data)
            submitted[presentationTimeUs] = System.nanoTime()
            c.queueInputBuffer(index, 0, data.size, presentationTimeUs,
                if (isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            queueBacklog = submitted.size
            // Hard cap for broken decoders that accept data but never render.
            if (submitted.size > 120) { failed = true; dropped++; return false }
            drainOutput()
            return true
        } catch (_: IllegalStateException) { failed = true; dropped++; return false }
    }
    private fun drainOutput() {
        val c = codec ?: return
        if (failed) return
        try {
            while (true) {
                val index = c.dequeueOutputBuffer(info, 0)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) break
                if (index < 0) continue
                val started = submitted.remove(info.presentationTimeUs)
                c.releaseOutputBuffer(index, true)
                if (started != null) {
                    lastDecodeUs = ((System.nanoTime() - started) / 1000).coerceAtLeast(0)
                    durations.addLast(lastDecodeUs)
                    while (durations.size > 120) durations.removeFirst()
                }
                queueBacklog = submitted.size
            }
        } catch (_: IllegalStateException) { failed = true }
    }
    @Synchronized fun stats(): PeerStats {
        val times = durations.sorted()
        return PeerStats(decodeUs = if (times.isEmpty()) 0 else times[times.size / 2],
            queueFrames = queueBacklog.toLong(), droppedFrames = dropped)
    }
}
