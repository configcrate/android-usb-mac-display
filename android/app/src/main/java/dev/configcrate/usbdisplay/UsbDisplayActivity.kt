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
import android.view.SurfaceHolder
import android.view.WindowManager
import android.widget.TextView
import dev.configcrate.usbdisplay.decode.LowLatencyVideoDecoder
import dev.configcrate.usbdisplay.input.TouchForwarder
import dev.configcrate.usbdisplay.render.VideoSurfaceView
import dev.configcrate.usbdisplay.transport.*
import java.nio.ByteBuffer
import java.nio.ByteOrder

class UsbDisplayActivity : Activity() {
    companion object {
        private const val PERMISSION = "dev.configcrate.usbdisplay.USB_PERMISSION"
    }
    private lateinit var video: VideoSurfaceView
    private lateinit var status: TextView
    private lateinit var touch: TouchForwarder
    private val ui = Handler(Looper.getMainLooper())
    private val manager by lazy { getSystemService(Context.USB_SERVICE) as UsbManager }
    @Volatile private var transport: UsbAccessoryTransport? = null
    @Volatile private var decoder: LowLatencyVideoDecoder? = null
    private var accessory: UsbAccessory? = null
    private var config: StreamConfig? = null
    private var generation = 0
    @Volatile private var frameCount = 0L
    @Volatile private var keyframes = 0
    @Volatile private var token = 0L
    @Volatile private var pingSent = 0L
    @Volatile private var rttUs = 0L
    @Volatile private var waitingIDR = true
    @Volatile private var lastRequestUs = 0L
    private var destroyed = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                PERMISSION -> {
                    val a = getAccessory(intent)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && a != null) connect(a)
                    else status.text = "USB 权限未允许。重新插线可再次授权。"
                }
                UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> handle(intent)
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    if (getAccessory(intent) == accessory) disconnect("已断开。重新插线并在 Mac 再次运行。")
                }
            }
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_usb_display)
        video = findViewById(R.id.video_surface); status = findViewById(R.id.status_text)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Do not display potentially sensitive Mac content over the phone lock screen.
        touch = TouchForwarder(video)
        video.setOnTouchListener { _, event -> touch.onTouchEvent(event) }
        video.onSurfaceReady = { h -> config?.let { buildDecoder(it, h) } }
        video.onSurfaceDestroyed = { releaseDecoder() }
        val filter = IntentFilter(PERMISSION).apply {
            addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(receiver, filter)
        handle(intent)
    }
    private fun getAccessory(intent: Intent?): UsbAccessory? =
        if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        else @Suppress("DEPRECATION") intent?.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
    private fun ours(a: UsbAccessory) = a.manufacturer == "ConfigCrate" && a.model == "USB Display"
    private fun handle(intent: Intent?) {
        val a = getAccessory(intent)?.takeIf { ours(it) }
            ?: manager.accessoryList?.firstOrNull { ours(it) }
        if (a == null) { status.text = "等待 Mac 连接…\n请在 Mac 上运行 usbdisplayctl run"; return }
        if (manager.hasPermission(a)) connect(a)
        else {
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pending = PendingIntent.getBroadcast(this, 0, Intent(PERMISSION).setPackage(packageName),
                flags or PendingIntent.FLAG_UPDATE_CURRENT)
            manager.requestPermission(a, pending)
            status.text = "请允许 USB 连接…"
        }
    }
    override fun onNewIntent(intent: Intent?) { super.onNewIntent(intent); handle(intent) }
    private fun connect(a: UsbAccessory) {
        if (destroyed || !ours(a)) return
        if (accessory == a && transport?.isOpen == true) return
        disconnect("")
        accessory = a
        val currentGeneration = generation
        val t = UsbAccessoryTransport(manager, a)
        transport = t
        t.onFrame = { header, payload ->
            if (transport === t && !destroyed) receive(header, payload, currentGeneration)
        }
        t.onError = { error -> ui.post {
            if (transport === t) disconnect("USB 断开: ${error.message}\n重新插线并在 Mac 再次运行。")
        } }
        try {
            if (!t.open()) { disconnect("USB 打开失败。检查权限或其他占用应用。"); return }
        } catch (error: Exception) { disconnect("USB 打开失败: ${error.message}"); return }
        touch.send = { t.sendTouch(it) }
        status.text = "USB 已连接，等待 Mac 视频配置…"
        statsLoop(t, currentGeneration)
        // Readiness is sent only after CONFIG + valid Surface + decoder configure.
    }
    private fun releaseDecoder() {
        val old = decoder; decoder = null
        old?.release()
        waitingIDR = true
    }
    private fun disconnect(message: String) {
        generation++
        ui.removeCallbacksAndMessages(null)
        touch.send = null
        val old = transport; transport = null; old?.close()
        releaseDecoder()
        config = null; accessory = null; frameCount = 0; keyframes = 0
        lastRequestUs = 0; rttUs = 0
        status.text = message
    }
    private fun buildDecoder(c: StreamConfig, holder: SurfaceHolder) {
        if (!holder.surface.isValid || destroyed) return
        if (decoder != null && config?.epoch == c.epoch) return
        releaseDecoder()
        try {
            decoder = LowLatencyVideoDecoder(holder.surface).also { it.configure(c) }
            video.setVideoSize(c.width, c.height)
            requestIDR(true)
        } catch (error: Exception) {
            status.text = "解码器初始化失败: ${error.message}"
        }
    }
    @Synchronized private fun requestIDR(force: Boolean = false) {
        val now = System.nanoTime() / 1000
        if (!force && now - lastRequestUs < 500_000) return
        lastRequestUs = now
        waitingIDR = true
        transport?.sendRequestKeyframe(); keyframes++
    }
    private fun receive(h: FrameHeader, bytes: ByteArray, g: Int) {
        when (h.type) {
            USBD.TYPE_CONFIG -> {
                val c = StreamConfig.decode(bytes) ?: return
                if (c.width !in 320..3840 || c.height !in 240..2160 || c.fps !in 1..60 || c.codec != VideoCodec.H264) return
                ui.post {
                    if (g != generation || destroyed) return@post
                    val changed = config?.epoch != c.epoch
                    if (changed) releaseDecoder()
                    config = c
                    buildDecoder(c, video.holder)
                }
            }
            USBD.TYPE_VIDEO -> {
                val d = decoder ?: return
                if (waitingIDR && !h.isKeyframe) { requestIDR(); return }
                val ok = d.feed(bytes, h.isKeyframe, System.nanoTime() / 1000)
                if (!ok) requestIDR()
                else { if (h.isKeyframe) waitingIDR = false; frameCount++ }
            }
            USBD.TYPE_PING -> if (bytes.size == 4) {
                val echoed = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
                transport?.sendPong(echoed, System.nanoTime() / 1000)
            }
            USBD.TYPE_PONG -> if (bytes.size == 8) {
                val echoed = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
                if (echoed == token) rttUs = (System.nanoTime() / 1000 - pingSent).coerceAtLeast(0)
            }
        }
    }
    private fun statsLoop(t: UsbAccessoryTransport, g: Int) {
        ui.post(object : Runnable {
            override fun run() {
                if (g != generation || destroyed || transport !== t || !t.isOpen) return
                token = (token + 1) and 0xffffffffL
                pingSent = System.nanoTime() / 1000
                t.sendPing(token)
                val d = decoder
                val stats = d?.stats() ?: PeerStats()
                t.sendStats(stats.copy(rttUs = rttUs))
                if (d != null) {
                    val c = config
                    status.text = "${c?.width}×${c?.height} · ${c?.fps} fps\n" +
                        "USB RTT ${rttUs / 1000.0} ms（非显示延迟）\n" +
                        "解码排队 ${stats.queueFrames} · 已收 ${frameCount} 帧"
                    if (waitingIDR) requestIDR()
                }
                ui.postDelayed(this, 1000)
            }
        })
    }
    override fun onDestroy() {
        destroyed = true
        disconnect("")
        runCatching { unregisterReceiver(receiver) }
        super.onDestroy()
    }
}
