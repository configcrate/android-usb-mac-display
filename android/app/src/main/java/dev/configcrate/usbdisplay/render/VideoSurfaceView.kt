package dev.configcrate.usbdisplay.render

import android.content.Context
import android.util.AttributeSet
import android.view.SurfaceHolder
import android.view.SurfaceView

/** Measure the actual SurfaceView to the video's aspect ratio, centred by its parent. */
class VideoSurfaceView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) :
    SurfaceView(context, attrs), SurfaceHolder.Callback {
    private var videoWidth = 0
    private var videoHeight = 0
    var onSurfaceReady: ((SurfaceHolder) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null
    init { holder.addCallback(this) }
    fun setVideoSize(w: Int, h: Int) {
        if (w == videoWidth && h == videoHeight) return
        videoWidth = w; videoHeight = h; requestLayout()
    }
    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val w = MeasureSpec.getSize(widthSpec)
        val h = MeasureSpec.getSize(heightSpec)
        if (videoWidth <= 0 || videoHeight <= 0) { super.onMeasure(widthSpec, heightSpec); return }
        val scale = minOf(w.toFloat() / videoWidth, h.toFloat() / videoHeight)
        setMeasuredDimension((videoWidth * scale).toInt().coerceAtLeast(1),
            (videoHeight * scale).toInt().coerceAtLeast(1))
    }
    fun normalizeTouch(x: Float, y: Float): Pair<Int, Int> =
        ((x / width.coerceAtLeast(1)).coerceIn(0f, 1f) * 65535).toInt() to
            ((y / height.coerceAtLeast(1)).coerceIn(0f, 1f) * 65535).toInt()
    override fun surfaceCreated(holder: SurfaceHolder) { onSurfaceReady?.invoke(holder) }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) { onSurfaceDestroyed?.invoke() }
}
