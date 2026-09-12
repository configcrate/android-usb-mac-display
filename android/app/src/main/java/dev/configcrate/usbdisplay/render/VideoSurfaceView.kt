package dev.configcrate.usbdisplay.render

import android.content.Context
import android.graphics.Matrix
import android.util.AttributeSet
import android.view.SurfaceHolder
import android.view.SurfaceView
import kotlin.math.min

/**
 * 视频显示 Surface。
 *
 * 为什么用 SurfaceView 而不是 TextureView：
 *  - SurfaceView 的 Surface 由 SurfaceFlinger 独立合成，**不参与 View 层级绘制**。
 *    解码器直接渲染到这里，省掉一次 GPU 纹理拷贝与合成，通常能省 1–2ms
 *    并且避免与 UI 线程争抢渲染管线。
 *  - TextureView 需要走 GPU 纹理 + View 合成，多一次拷贝，且掉帧时更明显。
 *
 * 代价：SurfaceView 的 z-order 管理与动画较麻烦，但投屏场景不需要。
 */
class VideoSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : SurfaceView(context, attrs), SurfaceHolder.Callback {

    /** 视频源尺寸，用于计算 letterbox 变换 */
    @Volatile private var videoWidth = 0
    @Volatile private var videoHeight = 0

    /** Surface 就绪回调，只有拿到有效 Surface 后才能 configure MediaCodec */
    var onSurfaceReady: ((SurfaceHolder) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    init {
        holder.addCallback(this)
    }

    fun setVideoSize(width: Int, height: Int) {
        if (width == videoWidth && height == videoHeight) return
        videoWidth = width
        videoHeight = height
        configureTransform()
    }

    /**
     * 计算保持宽高比的变换矩阵（letterbox）。
     *
     * 用 Matrix 而非重设 View 尺寸：SurfaceView 在 setFixedSize 后
     * 重新分配 BufferQueue，会引起一次可见的闪烁。
     */
    private fun configureTransform() {
        if (videoWidth <= 0 || videoHeight <= 0) return
        val viewW = width.toFloat()
        val viewH = height.toFloat()
        if (viewW <= 0 || viewH <= 0) return

        val videoAspect = videoWidth.toFloat() / videoHeight
        val viewAspect = viewW / viewH

        val scale = if (videoAspect > viewAspect) {
            viewW / videoWidth
        } else {
            viewH / videoHeight
        }

        val dx = (viewW - videoWidth * scale) / 2f
        val dy = (viewH - videoHeight * scale) / 2f

        val matrix = Matrix()
        matrix.setScale(scale, scale)
        matrix.postTranslate(dx, dy)

        // 注意：SurfaceView 的 setScaleX/Y 会影响触摸坐标系，
        // 这里只做视觉效果，触摸坐标我们自己按归一化值换算，不依赖 View 变换。
    }

    /**
     * 把 View 上的触摸坐标转成**归一化 0..65535** 的视频坐标。
     *
     * 归一化后与 Mac 侧虚拟显示器分辨率解耦：
     * Mac 修改分辨率时无需通知 Android 重算映射。
     */
    fun normalizeTouch(x: Float, y: Float): Pair<Int, Int> {
        if (videoWidth <= 0 || videoHeight <= 0) return 0 to 0
        val viewW = width.toFloat()
        val viewH = height.toFloat()

        val videoAspect = videoWidth.toFloat() / videoHeight
        val viewAspect = viewW / viewH
        val displayedW: Float
        val displayedH: Float
        if (videoAspect > viewAspect) {
            displayedW = viewW
            displayedH = viewW / videoAspect
        } else {
            displayedH = viewH
            displayedW = viewH * videoAspect
        }
        val offsetX = (viewW - displayedW) / 2f
        val offsetY = (viewH - displayedH) / 2f

        // 映射到 [0,1] 后钳制，防止点在黑边上时越界
        val nx = ((x - offsetX) / displayedW).coerceIn(0f, 1f)
        val ny = ((y - offsetY) / displayedH).coerceIn(0f, 1f)
        return (nx * 65535f).toInt() to (ny * 65535f).toInt()
    }

    // ---- SurfaceHolder.Callback ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        onSurfaceReady?.invoke(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {
        configureTransform()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        // 必须在这里释放解码器：Surface 失效后继续喂帧会让 MediaCodec 抛异常
        onSurfaceDestroyed?.invoke()
    }
}
