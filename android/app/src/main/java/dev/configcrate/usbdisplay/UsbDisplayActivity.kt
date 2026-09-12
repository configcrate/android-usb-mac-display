package dev.configcrate.usbdisplay

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.WindowManager
import android.widget.TextView
import android.widget.Toast
import dev.configcrate.usbdisplay.decode.LowLatencyVideoDecoder
import dev.configcrate.usbdisplay.input.TouchForwarder
import dev.configcrate.usbdisplay.render.VideoSurfaceView
import dev.configcrate.usbdisplay.transport.PeerStats
import dev.configcrate.usbdisplay.transport.StreamConfig
import dev.configcrate.usbdisplay.transport.USBD
import dev.configcrate.usbdisplay.transport.UsbAccessoryTransport
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * USB 副屏主界面。
 *
 * 生命周期要点：
 *  - 必须 `setShowWhenLocked` / 保持屏幕常亮：作为副屏时用户可能长时间不碰手机
 *  - 必须申请 `USB_PERMISSION` 才能 openAccessory
 *  - 必须在 surfaceDestroyed 时释放解码器，否则重新进入时 configure 会失败
 */
class UsbDisplayActivity : Activity() {

    companion object {
        private const val TAG = "UsbDisplayActivity"
        private const val ACTION_USB_PERMISSION = "dev.configcrate.usbdisplay.USB_PERMISSION"
        private const val STATS_INTERVAL_MS = 500L
        private const val PING_INTERVAL_MS = 1000L
    }

    private lateinit var surfaceView: VideoSurfaceView
    private lateinit var statusText: TextView

    private var transport: UsbAccessoryTransport? = null
    private var decoder: LowLatencyVideoDecoder? = null
    private lateinit var touchForwarder: TouchForwarder

    private var currentConfig: StreamConfig? = null
    private var localStats = PeerStats()
    private var peerStats = PeerStats()

    private val uiHandler = Handler(Looper.getMainLooper())
    private var pingSentUpstreamUs = 0L
    private var lastRttUs = 0L
    private var frameCount = 0L
    private var keyframeRequests = 0

    private val usbManager by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }

    // ---- USB 权限广播 ----

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            val accessory = intent.getParcelableExtra<UsbAccessory>(UsbManager.EXTRA_ACCESSORY)
            if (granted && accessory != null) {
                connect(accessory)
            } else {
                toast("USB 权限被拒绝")
                finish()
            }
        }
    }

    // ---- 生命周期 ----

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_usb_display)

        surfaceView = findViewById(R.id.video_surface)
        statusText = findViewById(R.id.status_text)

        // 作为副屏：常亮 + 锁屏上也显示
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        touchForwarder = TouchForwarder(surfaceView)

        // SurfaceView 自身不接收触摸事件（它不参与 View 事件分发），
        // 必须显式挂 OnTouchListener。
        surfaceView.setOnTouchListener { _, event -> touchForwarder.onTouchEvent(event) }

        surfaceView.onSurfaceReady = { holder -> onVideoSurfaceReady(holder) }
        surfaceView.onSurfaceDestroyed = {
            decoder?.release()
            decoder = null
        }

        registerReceiverCompat()
        handleAccessoryIntent(intent)
    }

    private fun registerReceiverCompat() {
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(usbPermissionReceiver, filter)
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        handleAccessoryIntent(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        uiHandler.removeCallbacksAndMessages(null)
        runCatching { unregisterReceiver(usbPermissionReceiver) }
        decoder?.release()
        decoder = null
        transport?.close()
        transport = null
    }

    // ---- 连接 ----

    private fun handleAccessoryIntent(intent: Intent?) {
        val accessory: UsbAccessory? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
            }

        if (accessory == null) {
            // 可能不是通过 accessory attach 启动的，主动查一下
            val attached = usbManager.accessoryList
            if (attached.isNullOrEmpty()) {
                setStatus("等待 Mac 连接…\n请在 Mac 上运行 usbdisplayctl run")
                return
            }
            requestPermission(attached[0])
            return
        }

        if (!usbManager.hasPermission(accessory)) {
            requestPermission(accessory)
        } else {
            connect(accessory)
        }
    }

    private fun requestPermission(accessory: UsbAccessory) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val pi = PendingIntent.getBroadcast(
            this, 0, Intent(ACTION_USB_PERMISSION), flags)
        usbManager.requestPermission(accessory, pi)
        setStatus("请求 USB 权限…")
    }

    private fun connect(accessory: UsbAccessory) {
        val t = UsbAccessoryTransport(usbManager, accessory)
        t.onFrame = ::onFrame
        t.onError = { err ->
            uiHandler.post { setStatus("USB 错误: ${err.message}") }
        }
        if (!t.open()) {
            setStatus("打开 accessory 失败\n设备可能被其他 App 占用")
            return
        }
        transport = t

        touchForwarder.send = { event -> t.sendTouch(event) }

        // 立刻通知主机：本端已就绪，可以开始推流。
        // 主机在收到此消息前不推帧，避免首批帧全被丢弃。
        t.sendRequestKeyframe()
        keyframeRequests++

        setStatus("已连接：${accessory.model}\n等待视频流…")
        startStatsLoop()
    }

    // ---- 视频管线 ----

    private fun onVideoSurfaceReady(holder: SurfaceHolder) {
        // Surface 就绪后，如果已经收到过 config，立即建解码器。
        // 若还没收到 config，等收到时再建（见 onFrame）。
        currentConfig?.let { buildDecoder(it, holder) }
    }

    private fun buildDecoder(config: StreamConfig, holder: SurfaceHolder) {
        decoder?.release()
        decoder = try {
            LowLatencyVideoDecoder(holder.surface)
                .also { it.configure(config) }
        } catch (t: Throwable) {
            Log.e(TAG, "解码器创建失败", t)
            setStatus("解码器初始化失败: ${t.message}")
            null
        }
        surfaceView.setVideoSize(config.width, config.height)
    }

    /**
     * 帧分发。运行在 USB reader 线程，**不能做耗时操作**。
     */
    private fun onFrame(header: dev.configcrate.usbdisplay.transport.FrameHeader, payload: ByteArray) {
        when (header.type) {
            USBD.TYPE_CONFIG -> {
                val config = StreamConfig.decode(payload) ?: return
                currentConfig = config
                uiHandler.post {
                    val holder = surfaceView.holder
                    if (holder.surface?.isValid == true) {
                        buildDecoder(config, holder)
                    }
                    setStatus("视频 ${config.width}x${config.height}@${config.fps}\n" +
                            "码率 ${config.bitrateBps / 1_000_000} Mbps")
                }
            }

            USBD.TYPE_VIDEO -> {
                val dec = decoder ?: run {
                    // 解码器未就绪：请求关键帧，丢弃本帧
                    if (frameCount % 60L == 0L) {
                        transport?.sendRequestKeyframe()
                        keyframeRequests++
                    }
                    return
                }
                frameCount++
                val ptsUs = System.nanoTime() / 1000
                val ok = dec.feed(payload, header.isKeyframe, ptsUs)
                if (!ok && header.isKeyframe) {
                    // 关键帧都喂不进去说明解码器状态异常，请求重发
                    transport?.sendRequestKeyframe()
                    keyframeRequests++
                }
            }

            USBD.TYPE_PING -> {
                if (payload.size >= 4) {
                    val echoed = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).int
                        .toLong() and 0xFFFFFFFFL
                    transport?.sendPong(echoed, System.nanoTime() / 1000)
                }
            }

            USBD.TYPE_PONG -> {
                if (payload.size >= 4) {
                    val echoed = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).int
                        .toLong() and 0xFFFFFFFFL
                    if (echoed == pingSentUpstreamUs) {
                        lastRttUs = (System.nanoTime() / 1000 - echoed) and 0xFFFFFFFFL
                    }
                }
            }

            USBD.TYPE_STATS -> {
                peerStats = PeerStats.decode(payload)
            }

            else -> Unit
        }
    }

    // ---- 统计上报 ----

    private fun startStatsLoop() {
        uiHandler.post(object : Runnable {
            override fun run() {
                val t = transport ?: return
                val dec = decoder

                // Ping（RTT）
                pingSentUpstreamUs = System.nanoTime() / 1000
                t.sendPing(pingSentUpstreamUs)

                // 上报本端统计
                val base = dec?.stats() ?: PeerStats()
                t.sendStats(base.copy(rttUs = lastRttUs))

                // 积压时把建议码率告知主机，驱动其自适应闭环
                if (dec != null && dec.isBacklogged()) {
                    val suggest = dec.suggestBitrate(currentConfig?.bitrateBps ?: 8_000_000)
                    t.sendStats(PeerStats(targetBitrateBps = suggest))
                }

                updateStatusLine(dec)
                uiHandler.postDelayed(this, STATS_INTERVAL_MS)
            }
        })
    }

    private fun updateStatusLine(dec: LowLatencyVideoDecoder?) {
        val cfg = currentConfig ?: return
        setStatus(buildString {
            append("${cfg.width}x${cfg.height}@${cfg.fps}\n")
            append("码率建议 ${cfg.bitrateBps / 1_000_000} Mbps\n")
            append("RTT ${lastRttUs / 1000.0} ms\n")
            append("解码 ${((dec?.lastDecodeUs ?: 0) / 1000.0)} ms\n")
            append("积压 ${dec?.queueBacklog ?: 0} 帧\n")
            append("帧 ${frameCount}  关键帧请求 ${keyframeRequests}")
        })
    }

    // ---- UI 小工具 ----

    private fun setStatus(text: String) {
        uiHandler.post {
            statusText.text = text
        }
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}
