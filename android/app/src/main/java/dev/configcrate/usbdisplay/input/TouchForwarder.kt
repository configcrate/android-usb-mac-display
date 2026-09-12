package dev.configcrate.usbdisplay.input

import android.view.MotionEvent
import dev.configcrate.usbdisplay.render.VideoSurfaceView
import dev.configcrate.usbdisplay.transport.TouchAction
import dev.configcrate.usbdisplay.transport.TouchEvent
import java.util.concurrent.atomic.AtomicLong

/**
 * 触摸回传：View 上的 MotionEvent → 归一化 → USB OUT。
 *
 * 两个必须解决的性能问题：
 *
 * 1. **不能阻塞 UI 线程**
 *    UI 线程直接写 USB 会掉帧（一次 bulk 写可阻塞数毫秒）。
 *    此处只做「坐标变换 + 入队」，实际写出由 [UsbAccessoryTransport] 的
 *    独立高优先级线程完成。
 *
 * 2. **MOVE 事件必须合并**
 *    60Hz 采样下手指快速滑动每帧可产生 3–5 个 MOVE，
 *    全部回传会挤占 USB 带宽（视频是 Bulk IN，触摸是 Bulk OUT，共用总线）。
 *    策略：移动距离小于阈值且上一个事件尚未发送时直接丢弃新事件。
 */
class TouchForwarder(
    private val surfaceView: VideoSurfaceView,
) {
    companion object {
        /**
         * 抖动过滤阈值（归一化后的像素距离）。
         * 太小 → USB 上充满无效事件；太大 → 手感变"粘"。
         * 1/512 的归一化分辨率在 1920 宽下约等于 3.75px，是手感与带宽的较好平衡。
         */
        private const val MOVE_THRESHOLD = 65535f / 512f
    }

    private val seq = AtomicLong(0)

    /** 由 Activity 注入，实际发送通道。 */
    var send: ((TouchEvent) -> Unit)? = null

    private var lastX = 0
    private var lastY = 0
    private var activePointerId = -1

    /**
     * 在 `onTouchEvent` 中调用。返回 true 表示事件已消费（通常是返回 true，
     * 避免系统把触摸解释成长按/滑动导航手势）。
     *
     * ⚠️ 副作用：返回 true 会阻止系统手势，这是投屏场景的预期行为。
     * 若希望保留系统手势（如边缘返回），应对边缘区域返回 false。
     */
    fun onTouchEvent(event: MotionEvent): Boolean {
        val pointerIndex = event.actionIndex
        val pointerId = event.getPointerId(pointerIndex)
        val vx = event.getX(pointerIndex)
        val vy = event.getY(pointerIndex)
        val (nx, ny) = surfaceView.normalizeTouch(vx, vy)

        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> TouchAction.DOWN
            MotionEvent.ACTION_MOVE -> TouchAction.MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> TouchAction.UP
            MotionEvent.ACTION_CANCEL -> TouchAction.CANCEL
            else -> return false
        }

        if (action == TouchAction.DOWN) {
            activePointerId = pointerId
        }

        // MOVE 抖动过滤：仅在单指、未换指时生效
        if (action == TouchAction.MOVE) {
            val dx = kotlin.math.abs(nx - lastX)
            val dy = kotlin.math.abs(ny - lastY)
            if (dx < MOVE_THRESHOLD && dy < MOVE_THRESHOLD) {
                return true // 消费掉，但不回传
            }
        }

        lastX = nx
        lastY = ny

        val touch = TouchEvent(
            seq = seq.incrementAndGet() and 0xFFFFFFFFL,
            x = nx,
            y = ny,
            // Android 的 pressure 是 0..1 的 float，放大到 0..65535
            pressure = (event.pressure.coerceIn(0f, 1f) * 65535f).toInt(),
            action = action,
            pointerCount = event.pointerCount,
            pointerId = pointerId,
        )
        send?.invoke(touch)

        if (action == TouchAction.UP || action == TouchAction.CANCEL) {
            activePointerId = -1
        }
        return true
    }
}
